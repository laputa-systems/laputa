##! xinit service module for the wpa_supplicant Wi-Fi facility.
# The wpa_supplicant facility provider: a supervised longrun that manages
# Wi-Fi association.  Services that need Wi-Fi can declare `need: ["wpa_supplicant"]`.
# By default it manages all nl80211 wireless interfaces; override by setting
# WPA_SUPPLICANT_ARGS in /etc/conf.d/wpa_supplicant.
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
