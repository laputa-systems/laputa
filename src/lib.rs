//! mdevd: Rust replacement for mdevd and mdevd-coldplug.
//!
//! Layout: `config` (mdev.conf grammar), `uevent` (netlink intake),
//! `engine` (match and apply), `publish` (post-processing events).
//! Privileged filesystem, netlink, process, and device operations stay
//! behind narrow adapters defined in their modules.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn loop_version_pinned() {
        assert_eq!(crate::VERSION, env!("CARGO_PKG_VERSION"));
    }
}
