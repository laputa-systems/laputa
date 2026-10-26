##! xinit service module for the wpa_supplicant Wi-Fi facility.
## The xinit service record.
export let service = {
  name: "wpa_supplicant",
  kind: "longrun",
  command: process.command_argv(
    /usr/bin/wpa_supplicant,
    [
      "/usr/bin/wpa_supplicant",
      "-B",
      "-c",
      "/etc/wpa_supplicant/wpa_supplicant.conf",
    ],
    env: {
      PATH: "/usr/local/bin:/usr/bin:/bin:/sbin",
    },
  ),
  targets: [
    "boot",
  ],
  logging: "append",
}
