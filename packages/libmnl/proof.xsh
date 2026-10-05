##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# linux/netlink.h comes from linux-headers, a build-only dependency that proof
# roots do not hold, so the program declares the slice of libmnl's stable
# LIBMNL_1.0 ABI it calls instead of including libmnl.h. It links the shipped
# library and dumps the links of the proof's network namespace over a real
# NETLINK_ROUTE socket, which needs no capability; loopback is always there.
const program = r"""#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

struct nlmsghdr {
  uint32_t nlmsg_len;
  uint16_t nlmsg_type;
  uint16_t nlmsg_flags;
  uint32_t nlmsg_seq;
  uint32_t nlmsg_pid;
};
struct nlattr;
struct mnl_socket;
typedef int (*mnl_cb_t)(const struct nlmsghdr *nlh, void *data);
typedef int (*mnl_attr_cb_t)(const struct nlattr *attr, void *data);

struct mnl_socket *mnl_socket_open(int bus);
int mnl_socket_bind(struct mnl_socket *nl, unsigned int groups, pid_t pid);
unsigned int mnl_socket_get_portid(const struct mnl_socket *nl);
ssize_t mnl_socket_sendto(const struct mnl_socket *nl, const void *req, size_t size);
ssize_t mnl_socket_recvfrom(const struct mnl_socket *nl, void *buf, size_t size);
int mnl_socket_close(struct mnl_socket *nl);
struct nlmsghdr *mnl_nlmsg_put_header(void *buf);
void *mnl_nlmsg_put_extra_header(struct nlmsghdr *nlh, size_t size);
int mnl_cb_run(const void *buf, size_t numbytes, unsigned int seq, unsigned int portid, mnl_cb_t cb, void *data);
int mnl_attr_parse(const struct nlmsghdr *nlh, unsigned int offset, mnl_attr_cb_t cb, void *data);
uint16_t mnl_attr_get_type(const struct nlattr *attr);
const char *mnl_attr_get_str(const struct nlattr *attr);

/* Stable kernel netlink ABI values from linux/netlink.h and linux/rtnetlink.h. */
#define NETLINK_ROUTE 0
#define NLM_F_REQUEST 0x1
#define NLM_F_DUMP 0x300
#define RTM_GETLINK 18
#define IFLA_IFNAME 3
#define IFINFOMSG_SIZE 16
#define MNL_CB_ERROR (-1)
#define MNL_CB_STOP 0
#define MNL_CB_OK 1

static int link_attr(const struct nlattr *attr, void *data) {
  if (mnl_attr_get_type(attr) == IFLA_IFNAME && strcmp(mnl_attr_get_str(attr), "lo") == 0) {
    *(int *)data = 1;
  }
  return MNL_CB_OK;
}

static int link_msg(const struct nlmsghdr *nlh, void *data) {
  return mnl_attr_parse(nlh, IFINFOMSG_SIZE, link_attr, data) < 0 ? MNL_CB_ERROR : MNL_CB_OK;
}

int main(void) {
  static char buf[32768];
  struct mnl_socket *nl;
  struct nlmsghdr *nlh;
  unsigned char *family;
  unsigned int seq = 1, portid;
  int found = 0, ret;
  ssize_t n;

  nl = mnl_socket_open(NETLINK_ROUTE);
  if (nl == NULL || mnl_socket_bind(nl, 0, 0) < 0) {
    perror("libmnl socket");
    return 1;
  }
  portid = mnl_socket_get_portid(nl);

  nlh = mnl_nlmsg_put_header(buf);
  nlh->nlmsg_type = RTM_GETLINK;
  nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  nlh->nlmsg_seq = seq;
  family = mnl_nlmsg_put_extra_header(nlh, 1);
  *family = 0;
  if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) {
    perror("libmnl send");
    return 2;
  }

  ret = MNL_CB_OK;
  while (ret > MNL_CB_STOP) {
    n = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    if (n <= 0) {
      perror("libmnl recv");
      return 3;
    }
    ret = mnl_cb_run(buf, (size_t)n, seq, portid, link_msg, &found);
  }
  mnl_socket_close(nl);
  if (ret < 0) {
    perror("libmnl dump");
    return 4;
  }
  if (!found) {
    fprintf(stderr, "libmnl: RTM_GETLINK dump did not report lo\n");
    return 5;
  }
  puts("libmnl: lo");
  return 0;
}
"""

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libmnl")
  proof.ensure(fp"{root}/usr/include/libmnl/libmnl.h".exists()?, "libmnl", "missing libmnl.h")
  proof.ensure(fp"{root}/usr/lib/pkgconfig/libmnl.pc".exists()?, "libmnl", "missing libmnl.pc")
  proof.target_elf(root, p"usr/lib/libmnl.so.0.2.0", "libmnl")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"libmnl ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-libmnl" {
    fp"{tmp}/proof-libmnl.c".write(program)
    let binary = fp"{tmp}/proof-libmnl"
    run $cc fp"{tmp}/proof-libmnl.c" f"-L{root}/usr/lib" "-lmnl" "-o" $binary

    let libdir = fp"{root}/usr/lib".display()
    let out = run.text LD_LIBRARY_PATH=$libdir $binary
    proof.ensure(out.trim() == "libmnl: lo", "libmnl", f"unexpected link dump output: {out.trim()}")
    print "libmnl ok: RTM_GETLINK dump over NETLINK_ROUTE found lo"
  }
}
