use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wpa_supplicant")
  proof.ensure(fs.exists(fp"{root}/usr/bin/wpa_supplicant")?, "wpa_supplicant", "missing wpa_supplicant binary")
  proof.ensure(fs.exists(fp"{root}/usr/bin/wpa_cli")?, "wpa_supplicant", "missing wpa_cli binary")
  proof.ensure(fs.exists(fp"{root}/usr/bin/wpa_passphrase")?, "wpa_supplicant", "missing wpa_passphrase binary")

  proof.ensure(
    fs.exists(fp"{root}/usr/lib/xinit/services/wpa_supplicant.xsh")?,
    "wpa_supplicant",
    "missing service file",
  )

  proof.ensure(
    fs.exists(fp"{root}/etc/wpa_supplicant/wpa_supplicant.conf")?,
    "wpa_supplicant",
    "missing default config",
  )

  # Run the binaries against the proof root's libraries so the check covers
  # the libnl3 the package depends on, not the build host's.
  let wpa_supplicant = fp"{root}/usr/bin/wpa_supplicant"
  let wpa_passphrase = fp"{root}/usr/bin/wpa_passphrase"
  var version = ""
  var psk = ""

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
    version = run.text $wpa_supplicant "-v" ?
    psk = run.text $wpa_passphrase "IEEE" "password" ?
  }

  proof.ensure(
    "wpa_supplicant v2.12" in version,
    "wpa_supplicant",
    f"unexpected version banner: {version.trim()}",
  )

  # IEEE 802.11i Annex H.4 PSK test vector: passphrase "password", SSID
  # "IEEE". It exercises the internal SHA-1 and PBKDF2 implementations.
  proof.ensure(
    "psk=f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e" in psk,
    "wpa_supplicant",
    f"wpa_passphrase derived the wrong PSK: {psk.trim()}",
  )

  print "wpa_supplicant ok"
}

main(@args)
