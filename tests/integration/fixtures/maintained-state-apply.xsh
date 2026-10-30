##! Provision a maintained state staging tree through first_boot.apply.
##! The harness formats the result as the state disk. The authorized key is
##! a test-only public key; no secret ever enters the tree.
use system.first_boot

const document = """
hostname laputa-guest
operator probe
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl probe@laputa
network dhcp
tailscale no
identity new
"""

proc main(root: Str) {
  first_boot.apply(Path(root), document)
  print "applied"
}
