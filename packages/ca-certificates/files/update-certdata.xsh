#!/bin/xsh
##! XSH module `update-certdata` package and build operations.
# Update CA certificate bundle from curl.se (Mozilla-derived).

proc main(dest = /etc/ssl/certs/ca-certificates.crt) [fs, net, error] {
  let tmp = fp"{dest.parent}/.{dest.name}.tmp"
  dest.parent.mkdir()
  tmp.remove()
  defer tmp.remove()

  let _ = net.download(
    {url: "https://curl.se/ca/cacert.pem", dest: tmp, atomic: true, overwrite: true, fail_status: true},
  )?

  let body = tmp.read_text()?

  if "-----BEGIN CERTIFICATE-----" not in body {
    fail "downloaded CA bundle does not contain a PEM certificate"
  }

  tmp.rename(to: dest, overwrite: true)
  print f"update-certdata: updated {dest}"
}
