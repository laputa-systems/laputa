#!/bin/sh
set -eu
install -d -m 0755 /etc/ssh/authorized_keys
install -m 0600 -o root -g root /fixture/host_ed25519 /etc/ssh/ssh_host_ed25519_key
for user in root deploy plain; do
  install -m 0644 -o root -g root /fixture/client.pub "/etc/ssh/authorized_keys/$user"
done
exec /usr/sbin/sshd -D -e
