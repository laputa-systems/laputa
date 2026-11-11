FROM alpine:3.22

RUN apk add --no-cache openssh-server doas openrc shadow \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/openrc /run/sshd \
 && touch /run/openrc/softlevel \
 && sed -i 's/^#\?rc_sys=.*/rc_sys="docker"/' /etc/rc.conf \
 && adduser -D -s /bin/ash deploy \
 && adduser -D -s /bin/ash plain \
 && for user in deploy plain; do echo "$user:$(head -c 32 /dev/urandom | base64)" | chpasswd; done \
 && printf 'permit nopass deploy\n' > /etc/doas.d/deploy.conf \
 && chmod 0400 /etc/doas.d/deploy.conf

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/sbin/xinfra-entrypoint
RUN chmod 0755 /usr/local/sbin/xinfra-entrypoint

ENTRYPOINT ["/usr/local/sbin/xinfra-entrypoint"]
