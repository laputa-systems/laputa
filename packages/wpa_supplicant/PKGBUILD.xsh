##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "wpa_supplicant"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2.12"

## Package recipe export.
export const rel = "1"

# Internal TLS/crypto — no openssl needed.
# The nl80211 driver unconditionally includes <netlink/genl/genl.h>, so libnl3
# headers and library are required at build and runtime.
## Package recipe export.
export const deps = ["musl", "libnl3"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "linux-headers", "libnl3"]

## The build installs an xinit service module; xinit runs it at runtime.
export const runtime_only_deps = ["xinit"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://w1.fi/releases/wpa_supplicant-2.12.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6",
      },
    ],
  },
  {
    source: p"config",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"service.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"wpa_supplicant.conf",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"etc/wpa_supplicant/wpa_supplicant.conf",
    kind: "file",
  },
  {
    path: p"usr/bin/wpa_cli",
    kind: "binary",
  },
  {
    path: p"usr/bin/wpa_passphrase",
    kind: "binary",
  },
  {
    path: p"usr/bin/wpa_supplicant",
    kind: "binary",
  },
  {
    path: p"usr/lib/xinit/services/wpa_supplicant.xsh",
    kind: "file",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let src = fs.cwd()?
  let objs = fp"{dest}/../objs"

  objs.mkdir()
  fs.install(p"config", fp"{src}/wpa_supplicant/.config", 0o644, parents: true, overwrite: true)
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"

  var cflags = ["-O2", "-Wall", "-ffunction-sections", "-fdata-sections"]

  var includes = [
    "-I",
    fp"{src}/src".display(),
    "-I",
    fp"{src}/src/utils".display(),
    "-I",
    fp"{src}/wpa_supplicant".display(),
    "-I",
    "/usr/include",
  ]

  # The defines upstream's Makefile derives from the `config` file, as printed
  # by `make -n V=1`. CONFIG_SME, CONFIG_WNM, and CONFIG_BGSCAN follow from the
  # nl80211 driver and bgscan_simple; CONFIG_DEBUG_SYSLOG_FACILITY becomes
  # LOG_HOSTAPD.
  var defs = [
    "-DCONFIG_BACKEND_FILE",
    "-DCONFIG_BGSCAN",
    "-DCONFIG_BGSCAN_SIMPLE",
    "-DCONFIG_CRYPTO_INTERNAL",
    "-DCONFIG_CTRL_IFACE",
    "-DCONFIG_CTRL_IFACE_UNIX",
    "-DCONFIG_DEBUG_SYSLOG",
    "-DCONFIG_DRIVER_NL80211",
    "-DCONFIG_GETRANDOM",
    "-DCONFIG_INTERNAL_LIBTOMMATH",
    "-DCONFIG_INTERNAL_SHA384",
    "-DCONFIG_INTERNAL_SHA512",
    "-DCONFIG_SHA256",
    "-DCONFIG_SME",
    "-DCONFIG_WNM",
    "-DLOG_HOSTAPD=LOG_DAEMON",
  ]

  var ldflags = ["-L", "/usr/lib", "-lnl-3", "-lnl-genl-3", "-Wl,--gc-sections"]

  # Every object upstream's wpa_supplicant/Makefile builds for wpa_supplicant,
  # wpa_cli, and wpa_passphrase from the `config` file (all but their main
  # files), as listed by `make -n V=1 wpa_supplicant wpa_cli wpa_passphrase`
  # run in wpa_supplicant/ with that file as .config. No EAP method needs TLS,
  # so upstream links tls_none rather than the internal TLS client.
  let shared_sources = [
    p"src/utils/base64.c",
    p"src/utils/bitfield.c",
    p"src/utils/common.c",
    p"src/utils/config.c",
    p"src/utils/crc32.c",
    p"src/utils/edit.c",
    p"src/utils/eloop.c",
    p"src/utils/ip_addr.c",
    p"src/utils/os_unix.c",
    p"src/utils/radiotap.c",
    p"src/utils/wpa_debug.c",
    p"src/utils/wpabuf.c",
    p"src/common/cli.c",
    p"src/common/ctrl_iface_common.c",
    p"src/common/hw_features_common.c",
    p"src/common/ieee802_11_common.c",
    p"src/common/ptksa_cache.c",
    p"src/common/wpa_common.c",
    p"src/common/wpa_ctrl.c",
    p"src/crypto/aes-internal-dec.c",
    p"src/crypto/aes-internal-enc.c",
    p"src/crypto/aes-internal.c",
    p"src/crypto/aes-omac1.c",
    p"src/crypto/aes-unwrap.c",
    p"src/crypto/crypto_internal.c",
    p"src/crypto/md5-internal.c",
    p"src/crypto/md5.c",
    p"src/crypto/random.c",
    p"src/crypto/rc4.c",
    p"src/crypto/sha1-internal.c",
    p"src/crypto/sha1-pbkdf2.c",
    p"src/crypto/sha1-prf.c",
    p"src/crypto/sha1.c",
    p"src/crypto/sha256-internal.c",
    p"src/crypto/sha256-prf.c",
    p"src/crypto/sha256.c",
    p"src/crypto/sha384-internal.c",
    p"src/crypto/sha512-internal.c",
    p"src/crypto/tls_none.c",
    p"src/rsn_supp/pmksa_cache.c",
    p"src/rsn_supp/preauth.c",
    p"src/rsn_supp/wpa.c",
    p"src/rsn_supp/wpa_ie.c",
    p"src/drivers/driver_common.c",
    p"src/drivers/driver_nl80211.c",
    p"src/drivers/driver_nl80211_capa.c",
    p"src/drivers/driver_nl80211_event.c",
    p"src/drivers/driver_nl80211_monitor.c",
    p"src/drivers/driver_nl80211_scan.c",
    p"src/drivers/drivers.c",
    p"src/drivers/linux_ioctl.c",
    p"src/drivers/netlink.c",
    p"src/drivers/rfkill.c",
    p"src/l2_packet/l2_packet_linux.c",
    p"wpa_supplicant/bgscan.c",
    p"wpa_supplicant/bgscan_simple.c",
    p"wpa_supplicant/bss.c",
    p"wpa_supplicant/bssid_ignore.c",
    p"wpa_supplicant/config.c",
    p"wpa_supplicant/config_file.c",
    p"wpa_supplicant/ctrl_iface.c",
    p"wpa_supplicant/ctrl_iface_unix.c",
    p"wpa_supplicant/eap_register.c",
    p"wpa_supplicant/events.c",
    p"wpa_supplicant/notify.c",
    p"wpa_supplicant/op_classes.c",
    p"wpa_supplicant/robust_av.c",
    p"wpa_supplicant/rrm.c",
    p"wpa_supplicant/scan.c",
    p"wpa_supplicant/sme.c",
    p"wpa_supplicant/twt.c",
    p"wpa_supplicant/wmm_ac.c",
    p"wpa_supplicant/wnm_sta.c",
    p"wpa_supplicant/wpa_supplicant.c",
    p"wpa_supplicant/wpas_glue.c",
  ]

  let shared = make.c_static_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: src,
    sources: shared_sources,
    out_dir: fp"{objs}/shared-objs",
    out: fp"{objs}/libwpa-common.a",
    deps: [],
  })

  let multi = make.c_multi_program({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: src,
    out_dir: fp"{objs}/compile",
    groups: [],
    targets: [{
    name: "wpa_supplicant",
    groups: [],
    sources: [p"wpa_supplicant/main.c"],
    libs: [shared.output],
    ldflags,
    out: fp"{objs}/wpa_supplicant",
    deps: shared.deps,
  }, {
    name: "wpa_cli",
    groups: [],
    sources: [p"wpa_supplicant/wpa_cli.c"],
    libs: [shared.output],
    ldflags,
    out: fp"{objs}/wpa_cli",
    deps: shared.deps,
  }, {
    name: "wpa_passphrase",
    groups: [],
    sources: [p"wpa_supplicant/wpa_passphrase.c"],
    libs: [shared.output],
    ldflags,
    out: fp"{objs}/wpa_passphrase",
    deps: shared.deps,
  }],
  })?

  make.run_tasks(shared.tasks.extend(multi.tasks), make.jobs()?)
  let wpa_supplicant_out = multi.outputs.get("wpa_supplicant")?
  let wpa_cli_out = multi.outputs.get("wpa_cli")?
  let passphrase_out = multi.outputs.get("wpa_passphrase")?

  # Install under /usr/bin: baselayout symlinks /usr/sbin -> bin so
  # installing to /usr/sbin would fail proof extraction with "symlink escape".
  fs.install(wpa_supplicant_out, fp"{dest}/usr/bin/wpa_supplicant", 0o755, parents: true, overwrite: true)
  fs.install(wpa_cli_out, fp"{dest}/usr/bin/wpa_cli", 0o755, parents: true, overwrite: true)
  fs.install(passphrase_out, fp"{dest}/usr/bin/wpa_passphrase", 0o755, parents: true, overwrite: true)

  fs.install(
    p"service.xsh",
    fp"{dest}/usr/lib/xinit/services/wpa_supplicant.xsh",
    0o644,
    parents: true,
    overwrite: true,
  )

  fp"{dest}/etc/wpa_supplicant".mkdir()

  fs.install(
    p"wpa_supplicant.conf",
    fp"{dest}/etc/wpa_supplicant/wpa_supplicant.conf",
    0o600,
    parents: true,
    overwrite: true,
  )
}
