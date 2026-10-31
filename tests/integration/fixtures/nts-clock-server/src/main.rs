use std::{env, error::Error, fs, io, sync::{Arc, RwLock}, time::Duration};
use ntp_proto::{FilterAction, FilterList, KeyExchangeServer, KeySetProvider, NtpServerInfo, NtpVersion, NtsServerConfig, Server, ServerAction, ServerConfig, ServerReason, ServerResponse, ServerStatHandler, tls_utils};
use statime_base::{Clock, ClockError, LeapStatus, TAI, Timestamp, UTC, UniversalTimestamp};
use tokio::net::{TcpListener, UdpSocket};

fn raw_ms() -> io::Result<u64> {
    let mut value = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: value is valid writable storage for the duration of clock_gettime.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut value) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(value.tv_sec as u64 * 1000 + value.tv_nsec as u64 / 1_000_000)
}

#[derive(Clone)]
struct Oracle { base_ms: u64, origin_ms: u64 }
impl Clock<TAI> for Oracle {
    fn now(&self) -> Result<Timestamp<TAI>, ClockError> {
        let ms = self.base_ms + raw_ms().map_err(|_| ClockError::Unknown)? - self.origin_ms;
        Ok(UniversalTimestamp::from(Timestamp::<UTC>::from_seconds_nanos_since_unix_epoch(ms / 1000, (ms % 1000) as u32 * 1_000_000)).as_tai(37))
    }
    fn set_frequency(&self, _: f64) -> Result<Timestamp<TAI>, ClockError> { Err(ClockError::NotSupported) }
    fn get_frequency(&self) -> Result<f64, ClockError> { Err(ClockError::NotSupported) }
    fn max_frequency(&self) -> Result<f64, ClockError> { Err(ClockError::NotSupported) }
    fn step_clock(&self, _: statime_base::Duration) -> Result<Timestamp<TAI>, ClockError> { Err(ClockError::NotSupported) }
    fn error_estimate_update(&self, _: statime_base::Duration, _: statime_base::Duration) -> Result<(), ClockError> { Err(ClockError::NotSupported) }
    fn leap_update(&self, _: LeapStatus) -> Result<(), ClockError> { Err(ClockError::NotSupported) }
    fn synchronization_update(&self, _: bool) -> Result<(), ClockError> { Err(ClockError::NotSupported) }
}

#[derive(Default)]
struct Stats { accepted: u64, denied: u64 }
impl ServerStatHandler for Stats {
    fn register(&mut self, _: u8, nts: bool, _: ServerReason, response: ServerResponse) {
        if nts && response == ServerResponse::ProvideTime { self.accepted += 1; }
        else { self.denied += 1; }
        fs::write("/run/nts-oracle-accepted", self.accepted.to_string()).unwrap();
        fs::write("/run/nts-oracle-denied", self.denied.to_string()).unwrap();
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let mut args = env::args().skip(1);
    let base_ms = args.next().ok_or("missing base")?.parse()?;
    let origin_ms = args.next().ok_or("missing raw origin")?.parse()?;
    let ready = args.next().ok_or("missing readiness path")?;
    let inputs = args.next().ok_or("missing input directory")?;
    let chain = fs::read(format!("{inputs}/end.fullchain.pem"))?;
    let key = fs::read(format!("{inputs}/end.key"))?;
    let server = KeyExchangeServer::new(NtsServerConfig {
        certificate_chain: tls_utils::pemfile::certs(&mut &*chain).collect::<Result<Vec<_>, _>>()?,
        private_key: tls_utils::pemfile::private_key(&mut &*key)?,
        accepted_versions: vec![NtpVersion::V4], server: Some("127.0.0.1".into()), port: Some(32123), pool_authentication_tokens: vec![],
    })?;
    let keyset = KeySetProvider::new(1).get();
    let tcp = TcpListener::bind("127.0.0.1:32460").await?;
    let udp = UdpSocket::bind("127.0.0.1:32123").await?;
    let exchange_keys = keyset.clone();
    tokio::spawn(async move {
        loop {
            let (stream, _) = tcp.accept().await.unwrap();
            let _ = server.handle_connection(stream, &exchange_keys, || None::<()>).await;
        }
    });
    let config = ServerConfig {
        denylist: FilterList { filter: vec![], action: FilterAction::Deny },
        allowlist: FilterList { filter: vec!["127.0.0.0/8".parse()?], action: FilterAction::Ignore },
        rate_limiting_cache_size: 0, rate_limiting_cutoff: Duration::ZERO,
        require_nts: Some(FilterAction::Ignore), accepted_versions: vec![NtpVersion::V4],
    };
    let clock = Oracle { base_ms, origin_ms };
    let mut info = NtpServerInfo::default();
    info.ntp_snapshot.stratum = 1;
    info.time_snapshot.leap_indicator = Some(LeapStatus::None);
    let mut ntp = Server::new_internal(config, clock.clone(), Arc::new(RwLock::new(info)), keyset);
    let mut stats = Stats::default();
    fs::write(ready, b"ready\n")?;
    let mut input = [0; 2048];
    let mut output = [0; 2048];
    loop {
        let (len, peer) = udp.recv_from(&mut input).await?;
        if let ServerAction::Respond { message } = ntp.handle(peer.ip(), clock.now()?, &input[..len], &mut output, &mut stats) {
            if !std::path::Path::new("/run/nts-oracle-authenticate").exists() && stats.accepted > 0 {
                let millis = clock.base_ms + raw_ms()? - clock.origin_ms;
                let seconds = (millis / 1000 + 2_208_988_800) as u32;
                let fraction = (((millis % 1000) << 32) / 1000) as u32;
                let mut forged = [0_u8; 48];
                forged[0] = 0x24;
                forged[1] = 1;
                forged[2] = input[2];
                forged[3] = (-20_i8) as u8;
                forged[12..16].copy_from_slice(b"LOCL");
                forged[24..32].copy_from_slice(&input[40..48]);
                for offset in [16, 32, 40] {
                    forged[offset..offset + 4].copy_from_slice(&seconds.to_be_bytes());
                    forged[offset + 4..offset + 8].copy_from_slice(&fraction.to_be_bytes());
                }
                udp.send_to(&forged, peer).await?;
                fs::write("/run/nts-oracle-forged", stats.accepted.to_string())?;
            } else {
                udp.send_to(message, peer).await?;
            }
        }
    }
}
