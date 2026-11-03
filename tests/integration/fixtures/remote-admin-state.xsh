##! Provision the maintained state staging tree for the remote administration drill.
##! The host key is placed beforehand, so `identity restore` makes its fingerprint known
##! before the first boot. No secret enters the document.
use system.first_boot

proc main(root: Str, operator: Str, authorized_key: Str) {
  let document = f"hostname laputa-admin\noperator {operator}\nauthorized-key {authorized_key}\nnetwork dhcp\ntailscale no\nidentity restore\n"
  first_boot.apply(Path(root), document)
  print "applied"
}

