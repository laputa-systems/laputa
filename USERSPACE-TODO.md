## Networking

  leave interface configuration to userspace instead.
- ~~Implement DHCP support for the XSH `ifup` applet so `iface <name> inet dhcp`
  works through `/etc/network/interfaces`. This requires an XSH DHCP client, not
  shelling out to a borrowed userspace DHCP tool.~~ DONE — xsh/core/ifup.xsh has a
  minimal RFC 2131 DHCP client using the linux.dhcp_* primitives.
- ~~Implement `ifdown` compatibility for configured interfaces, including state
  removal and `down`/`post-down` hook phases.~~ DONE — xsh/core/ifdown.xsh mirrors
  ifup for teardown: pre-down/down/post-down hooks, DHCP RELEASE, address flush,
  link down, state file removal.
- ~~Update `laputa-installer` networking so it does not enable DHCP by default.
  Like Alpine setup, it should ask whether the target network should be static
  or DHCP and write the chosen configuration explicitly.~~ DONE — laputa-net
  default interfaces is loopback-only. setup-laputa asks [d]hcp or [s]tatic and
  writes the chosen config. CI smoke test explicitly configures DHCP and verifies
  it works end-to-end.
- Keep `inet6`/IPv6 out of scope for now. Laputa userspace networking is
  targeting IPv4 only.

## WiFi

- Add mac80211_hwsim to the Laputa kernel so wpa_supplicant can be smoke-tested
  in QEMU (the virt machine has no wireless hardware). With hwsim, the CI smoke
  test could create a simulated radio, associate via wpa_supplicant, and verify
  DHCP on the wireless interface — all inside the existing QEMU test harness.
