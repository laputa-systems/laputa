mod cli;
mod ntp_source;
mod server;

pub use cli::*;
use clock_steering::unix::UnixClock;
use ntp_proto::{
    NtpVersion, ProtocolVersion, SourceConfig, StepThreshold, SynchronizationConfig,
};
pub use ntp_source::*;
use serde::{Deserialize, Deserializer, Serialize};
pub use server::*;
use statime_algo::{ClockConfig, JumpThreshold, LinkConfig};
use statime_config::{
    ConfigError, ConfigPath, Configurable, ConfigurableAtomic, PartialValue, RootConfig,
    SystemConfigSetting,
};
use std::io;
use std::{
    fmt::Display,
    io::ErrorKind,
    net::SocketAddr,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    str::FromStr,
};
use tracing::{info, warn};

use super::{clock::NtpClockWrapper, tracing::LogLevel};

#[derive(Debug, Clone, Configurable)]
pub struct ObservabilityConfig {
    #[config(default)]
    pub log_level: Option<LogLevel>,
    #[config(default)]
    pub log_path: Option<PathBuf>,
    #[config(default)]
    pub log_path_metrics_exporter: Option<PathBuf>,
    #[config(default)]
    pub ansi_colors: Option<bool>,
    #[config(default)]
    pub observation_path: Option<PathBuf>,
    #[config(default = 0o666)]
    pub observation_permissions: u32,
    #[config(default="127.0.0.1:9975".parse().unwrap())]
    pub metrics_exporter_listen: SocketAddr,
}

impl Default for ObservabilityConfig {
    fn default() -> Self {
        let mut partial = <Self as Configurable>::Node::default();
        partial.apply_defaults();
        partial.resolve(&mut ConfigPath::root()).unwrap()
    }
}

/// Which system configuration to layer underneath the main configuration, if
/// any.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, ConfigurableAtomic)]
#[serde(untagged)]
pub enum UseSystemConfig {
    /// `true` reads the fragments supplied by the distribution, `false` uses no
    /// system configuration at all.
    Enabled(bool),

    /// A directory to read the fragments from, instead of the default one.
    Directory(PathBuf),
}

impl UseSystemConfig {
    pub const DEFAULT_SYSTEM_CONFIG: &str = "/usr/lib/ntpd-rs/system-config";
}

impl Default for UseSystemConfig {
    fn default() -> Self {
        Self::Enabled(false)
    }
}

/// The `[synchronization]` table: when the daemon may steer the clock and how
/// far it may step it.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize, ConfigurableAtomic)]
#[serde(transparent)]
pub struct SynchronizationSettings(pub SynchronizationConfig);

impl SynchronizationSettings {
    pub fn clock_config(&self) -> ClockConfig {
        let config = &self.0;
        let warn_on_every_jump = if config.warn_on_jump {
            JumpThreshold {
                backwards: Some(statime_base::Duration::ZERO),
                forwards: Some(statime_base::Duration::ZERO),
            }
        } else {
            JumpThreshold::default()
        };
        ClockConfig {
            startup_jump_warning_threshold: warn_on_every_jump.clone(),
            startup_jump_abort_threshold: jump_threshold(config.startup_step_panic_threshold),
            single_jump_warning_threshold: warn_on_every_jump,
            single_jump_abort_threshold: jump_threshold(config.single_step_panic_threshold),
            accumulated_jump_abort_threshold: config
                .accumulated_step_panic_threshold
                .map(|threshold| statime_base::Duration::from_f64_seconds(threshold.to_seconds())),
            ..ClockConfig::default()
        }
    }

    pub fn minimum_agreeing_sources(&self) -> usize {
        self.0.minimum_agreeing_sources
    }
}

fn jump_threshold(threshold: StepThreshold) -> JumpThreshold {
    let limit = |limit: Option<ntp_proto::NtpDuration>| {
        limit.map(|limit| statime_base::Duration::from_f64_seconds(limit.to_seconds()))
    };
    JumpThreshold {
        backwards: limit(threshold.backward),
        forwards: limit(threshold.forward),
    }
}

#[derive(Debug, Default, Configurable)]
pub struct Config {
    #[config(rename = "use-system-config", default)]
    #[allow(clippy::struct_field_names)]
    pub use_system_config: UseSystemConfig,
    #[config(rename = "source", default)]
    pub sources: Vec<NtpSourceConfig>,
    #[config(rename = "server", default)]
    pub servers: Vec<NtpServerConfig>,
    pub observability: ObservabilityConfig,
    #[config(default)]
    pub synchronization: SynchronizationSettings,
}

impl RootConfig for Config {
    fn use_system_config(partial: &Self::Partial) -> SystemConfigSetting {
        match &partial.use_system_config {
            statime_config::Setting::Unset => SystemConfigSetting::Unset,
            statime_config::Setting::Set {
                value: UseSystemConfig::Enabled(true),
                ..
            } => SystemConfigSetting::DefaultPath(UseSystemConfig::DEFAULT_SYSTEM_CONFIG.into()),
            statime_config::Setting::Set {
                value: UseSystemConfig::Enabled(false),
                ..
            } => SystemConfigSetting::None,
            statime_config::Setting::Set {
                value: UseSystemConfig::Directory(path),
                ..
            } => SystemConfigSetting::UserSpecifiedPath(path.clone()),
        }
    }
}

impl Config {
    fn from_first_file(file: Option<impl AsRef<Path>>) -> Result<Config, ConfigError> {
        // if an explicit file is given, always use that one
        if let Some(f) = file {
            let path: &Path = f.as_ref();
            info!(?path, "using config file");
            return Config::load(f);
        }

        // for the global file we also ignore it when there are permission errors, or if it does not exist.
        let global_path = Path::new("/etc/ntpd-rs/ntp.toml");
        match Config::load(global_path) {
            Err(ConfigError::CouldNotRead { path, cause })
                if path == global_path
                    && (cause.kind() == ErrorKind::NotFound
                        || cause.kind() == ErrorKind::PermissionDenied) =>
            {
                Ok(Config::default())
            }
            result => result,
        }
    }

    pub fn from_args(
        file: Option<&impl AsRef<Path>>,
        sources: Vec<NtpSourceConfig>,
        servers: Vec<NtpServerConfig>,
    ) -> Result<Config, ConfigError> {
        let mut config = Config::from_first_file(file.as_ref())?;

        if !sources.is_empty() {
            if !config.sources.is_empty() {
                info!("overriding sources from configuration");
            }
            config.sources = sources;
        }

        if !servers.is_empty() {
            if !config.servers.is_empty() {
                info!("overriding servers from configuration");
            }
            config.servers = servers;
        }

        Ok(config)
    }

    /// Count potential number of sources in configuration
    fn count_sources(&self) -> usize {
        let mut count = 0;
        for source in &self.sources {
            match source {
                NtpSourceConfig::Standard(_) => count += 1,
                NtpSourceConfig::Nts(_) => count += 1,
                NtpSourceConfig::Pool(config) => count += config.first.count,
                NtpSourceConfig::NtsPool(config) => count += config.first.count,
                NtpSourceConfig::Sock(_) => count += 1,
                #[cfg(feature = "pps")]
                NtpSourceConfig::Pps(_) => {} // PPS sources don't count
                #[cfg(target_os = "linux")]
                NtpSourceConfig::Csptp(_) => count += 1,
            }
        }
        count
    }

    /// Check that the config is reasonable. This function may panic if the
    /// configuration is egregious, although it doesn't do so currently.
    pub fn check(&self) -> bool {
        let mut ok = true;

        // Note: since we only check once logging is fully configured,
        // using those fields should always work. This is also
        // probably a good policy in general (config should always work
        // but we may panic here to protect the user from themselves)
        if self.sources.is_empty() {
            info!("No sources configured. Daemon will not change system time.");
        }

        let minimum = self.synchronization.minimum_agreeing_sources();
        let available = self.count_sources();
        if !self.sources.is_empty() && available < minimum {
            warn!(
                available,
                minimum,
                "Fewer sources are configured than `minimum-agreeing-sources`; the daemon will never steer the clock"
            );
            ok = false;
        }

        // FIXME: Reintroduce check on NTPv5 being draft once fields are available.

        // FIXME: Reintroduce check on NTS configuration once fields are available.

        ok
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};

    use statime_base::Duration;

    use super::*;

    fn load_text(contents: &str) -> Result<Config, ConfigError> {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "ntp-config-test-{}-{}.toml",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&path, contents).unwrap();
        let result = Config::load(&path);
        std::fs::remove_file(&path).unwrap();
        result
    }

    #[derive(Debug)]
    struct Seconds(Option<f64>);

    impl PartialEq<i64> for Seconds {
        fn eq(&self, expected: &i64) -> bool {
            self.0
                .is_some_and(|actual| (actual - *expected as f64).abs() < 1e-3)
        }
    }

    fn seconds(value: Option<Duration>) -> Seconds {
        Seconds(value.map(|value| value.as_seconds()))
    }

    #[test]
    fn shipped_sample_configs_load() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        for sample in ["ntp.toml", "docs/examples/conf/ntp.toml.default"] {
            Config::load(root.join(sample))
                .unwrap_or_else(|error| panic!("{sample} does not load: {error}"));
        }
    }

    #[test]
    fn synchronization_defaults_apply_without_a_table() {
        let config = load_text("[[source]]\nmode = \"pool\"\naddress = \"pool.example\"\n").unwrap();

        assert_eq!(config.synchronization, SynchronizationSettings::default());
        assert_eq!(config.synchronization.minimum_agreeing_sources(), 3);
    }

    #[test]
    fn synchronization_step_limits_reach_the_clock_config() {
        let config = load_text(
            r#"
[synchronization]
single-step-panic-threshold = 1800
startup-step-panic-threshold = { forward = "inf", backward = 600 }
accumulated-step-panic-threshold = 3600
minimum-agreeing-sources = 1
"#,
        )
        .unwrap();

        let clock = config.synchronization.clock_config();
        assert_eq!(seconds(clock.single_jump_abort_threshold.forwards), 1800);
        assert_eq!(seconds(clock.single_jump_abort_threshold.backwards), 1800);
        assert_eq!(clock.startup_jump_abort_threshold.forwards, None);
        assert_eq!(seconds(clock.startup_jump_abort_threshold.backwards), 600);
        assert_eq!(seconds(clock.accumulated_jump_abort_threshold), 3600);
        assert_eq!(config.synchronization.minimum_agreeing_sources(), 1);
    }

    #[test]
    fn default_step_policy_bounds_backward_startup_steps() {
        let clock = SynchronizationSettings::default().clock_config();

        assert_eq!(clock.startup_jump_abort_threshold.forwards, None);
        assert_eq!(seconds(clock.startup_jump_abort_threshold.backwards), 86400);
        assert_eq!(seconds(clock.single_jump_abort_threshold.forwards), 1000);
        assert_eq!(seconds(clock.single_jump_abort_threshold.backwards), 1000);
        assert_eq!(clock.accumulated_jump_abort_threshold, None);
    }

    #[test]
    fn warn_on_jump_false_clears_the_warning_thresholds() {
        let config = load_text("[synchronization]\nwarn-on-jump = false\n").unwrap();

        let clock = config.synchronization.clock_config();
        assert_eq!(clock.single_jump_warning_threshold.forwards, None);
        assert_eq!(clock.single_jump_warning_threshold.backwards, None);
    }

    #[test]
    fn fewer_sources_than_the_minimum_fails_the_check() {
        let one_server = "[[source]]\nmode = \"server\"\naddress = \"time.example\"\n";

        assert!(!load_text(one_server).unwrap().check());
        assert!(
            load_text(&format!(
                "{one_server}[synchronization]\nminimum-agreeing-sources = 1\n"
            ))
            .unwrap()
            .check()
        );
        assert!(
            load_text("[[source]]\nmode = \"pool\"\naddress = \"pool.example\"\ncount = 4\n")
                .unwrap()
                .check()
        );
    }

    #[test]
    fn unknown_synchronization_key_is_rejected() {
        let error = load_text("[synchronization]\nsingle-step-panic = 3\n").unwrap_err();

        assert!(error.to_string().contains("unknown field"), "{error}");
    }

    #[test]
    fn reference_id_longer_than_four_characters_is_rejected() {
        let error = load_text("[synchronization]\nreference-id = \"TOO_LONG\"\n").unwrap_err();

        assert!(
            error.to_string().contains("up to 4-character string"),
            "{error}"
        );
    }
}
