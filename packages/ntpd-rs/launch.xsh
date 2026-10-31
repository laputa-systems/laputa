##! Starts ntpd-rs with clock discipline privileges.
error NtpdLaunchError = IdentityMismatch(kind: Str, message: Str)

const ntp_id = 123
const cap_sys_time = 25
const runtime_dir = p"/run/ntpd-rs"
const administered_config = p"/etc/ntpd-rs/ntp.toml"
const packaged_config = p"/usr/share/ntpd-rs/ntp.toml"

pure config_path(administered_exists: Bool) -> Path {
  if administered_exists { administered_config } else { packaged_config }
}

proc main() [fs, process, env, error] {
  let owner = user.by_uid(ntp_id)?
  let owning_group = group.by_gid(ntp_id)?
  if owner.name != "ntpd-rs" or owner.gid != ntp_id or owning_group.name != "ntpd-rs" or ! owning_group.members.is_empty() {
    return Err(NtpdLaunchError.IdentityMismatch(kind: "ntpd-rs-identity", message: "UID and GID 123 must belong exclusively to ntpd-rs"))
  }

  if ! runtime_dir.exists()? {
    runtime_dir.mkdir(true)?
  }
  runtime_dir.chmod(0o755)?
  fs.chown(runtime_dir, owner)?
  fs.chgrp(runtime_dir, owning_group)?

  let privileges = linux.privileges()?
  for capability in range(privileges.last_capability + 1) {
    if capability != cap_sys_time {
      linux.drop_bounding_capability(capability)?
    }
  }

  linux.set_keep_capabilities(true)?
  unix.set_groups([])?
  unix.set_gid(ntp_id)?
  unix.set_uid(ntp_id)?
  linux.set_capabilities(effective: [cap_sys_time], permitted: [cap_sys_time], inheritable: [cap_sys_time])?
  linux.set_ambient_capability(cap_sys_time, true)?
  linux.set_no_new_privs()?

  let config = config_path(administered_config.exists()?)
  unix.exec(process.command_argv(/usr/bin/ntp-daemon, ["ntp-daemon", "-c", f"{config}"]))?
}
