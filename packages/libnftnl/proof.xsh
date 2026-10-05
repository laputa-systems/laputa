##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# The program compiles against the installed public headers, which need only
# libc, links the shipped library (and through it libmnl), and round-trips a
# table, a base chain with a hook, a rule with two expressions, and a set
# through nf_tables netlink messages. That exercises libnftnl's message
# builders and parsers without the kernel, so the proof needs no capability.
const program = r"""#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <libnftnl/chain.h>
#include <libnftnl/expr.h>
#include <libnftnl/rule.h>
#include <libnftnl/set.h>
#include <libnftnl/table.h>

/* Stable kernel ABI values from linux/netfilter.h and linux/netfilter/nf_tables.h. */
#define NFPROTO_IPV4 2
#define NF_INET_LOCAL_IN 1
#define NF_ACCEPT 1
#define NFT_REG_VERDICT 0
#define NFT_MSG_NEWTABLE 0
#define NFT_MSG_NEWCHAIN 3
#define NFT_MSG_NEWRULE 6
#define NFT_MSG_NEWSET 9

static char buf[65536];

static int fail(const char *what) {
  fprintf(stderr, "libnftnl: %s\n", what);
  return 1;
}

static int count_expr(struct nftnl_expr *expr, void *data) {
  const char *name = nftnl_expr_get_str(expr, NFTNL_EXPR_NAME);
  if (strcmp(name, "counter") == 0 || strcmp(name, "immediate") == 0) {
    (*(int *)data)++;
  }
  return 0;
}

int main(void) {
  struct nftnl_table *table = nftnl_table_alloc(), *table_back = nftnl_table_alloc();
  struct nftnl_chain *chain = nftnl_chain_alloc(), *chain_back = nftnl_chain_alloc();
  struct nftnl_rule *rule = nftnl_rule_alloc(), *rule_back = nftnl_rule_alloc();
  struct nftnl_set *set = nftnl_set_alloc(), *set_back = nftnl_set_alloc();
  struct nftnl_set_elem *elem = nftnl_set_elem_alloc();
  struct nftnl_expr *counter = nftnl_expr_alloc("counter");
  struct nftnl_expr *verdict = nftnl_expr_alloc("immediate");
  struct nlmsghdr *nlh;
  uint32_t address = 0x010200c0; /* 192.0.2.1 in network order */
  int exprs = 0;

  if (!table || !table_back || !chain || !chain_back || !rule || !rule_back || !set || !set_back || !elem || !counter || !verdict) {
    return fail("allocation failed");
  }

  nftnl_table_set_str(table, NFTNL_TABLE_NAME, "laputa");
  nftnl_table_set_u32(table, NFTNL_TABLE_FAMILY, NFPROTO_IPV4);
  nlh = nftnl_table_nlmsg_build_hdr(buf, NFT_MSG_NEWTABLE, NFPROTO_IPV4, 0, 1);
  nftnl_table_nlmsg_build_payload(nlh, table);
  if (nftnl_table_nlmsg_parse(nlh, table_back) < 0 ||
      strcmp(nftnl_table_get_str(table_back, NFTNL_TABLE_NAME), "laputa") != 0) {
    return fail("table did not round-trip");
  }

  nftnl_chain_set_str(chain, NFTNL_CHAIN_TABLE, "laputa");
  nftnl_chain_set_str(chain, NFTNL_CHAIN_NAME, "input");
  nftnl_chain_set_str(chain, NFTNL_CHAIN_TYPE, "filter");
  nftnl_chain_set_u32(chain, NFTNL_CHAIN_HOOKNUM, NF_INET_LOCAL_IN);
  nftnl_chain_set_s32(chain, NFTNL_CHAIN_PRIO, 0);
  nftnl_chain_set_u32(chain, NFTNL_CHAIN_POLICY, NF_ACCEPT);
  nlh = nftnl_chain_nlmsg_build_hdr(buf, NFT_MSG_NEWCHAIN, NFPROTO_IPV4, 0, 2);
  nftnl_chain_nlmsg_build_payload(nlh, chain);
  if (nftnl_chain_nlmsg_parse(nlh, chain_back) < 0 ||
      strcmp(nftnl_chain_get_str(chain_back, NFTNL_CHAIN_NAME), "input") != 0 ||
      strcmp(nftnl_chain_get_str(chain_back, NFTNL_CHAIN_TYPE), "filter") != 0 ||
      nftnl_chain_get_u32(chain_back, NFTNL_CHAIN_HOOKNUM) != NF_INET_LOCAL_IN) {
    return fail("base chain did not round-trip");
  }

  nftnl_rule_set_str(rule, NFTNL_RULE_TABLE, "laputa");
  nftnl_rule_set_str(rule, NFTNL_RULE_CHAIN, "input");
  nftnl_rule_set_u32(rule, NFTNL_RULE_FAMILY, NFPROTO_IPV4);
  nftnl_rule_add_expr(rule, counter);
  nftnl_expr_set_u32(verdict, NFTNL_EXPR_IMM_DREG, NFT_REG_VERDICT);
  nftnl_expr_set_u32(verdict, NFTNL_EXPR_IMM_VERDICT, NF_ACCEPT);
  nftnl_rule_add_expr(rule, verdict);
  nlh = nftnl_rule_nlmsg_build_hdr(buf, NFT_MSG_NEWRULE, NFPROTO_IPV4, 0, 3);
  nftnl_rule_nlmsg_build_payload(nlh, rule);
  if (nftnl_rule_nlmsg_parse(nlh, rule_back) < 0 ||
      nftnl_expr_foreach(rule_back, count_expr, &exprs) < 0 || exprs != 2) {
    return fail("rule expressions did not round-trip");
  }

  nftnl_set_set_str(set, NFTNL_SET_TABLE, "laputa");
  nftnl_set_set_str(set, NFTNL_SET_NAME, "blocked");
  nftnl_set_set_u32(set, NFTNL_SET_FAMILY, NFPROTO_IPV4);
  nftnl_set_set_u32(set, NFTNL_SET_KEY_LEN, sizeof(address));
  nftnl_set_set_u32(set, NFTNL_SET_ID, 1);
  nftnl_set_elem_set(elem, NFTNL_SET_ELEM_KEY, &address, sizeof(address));
  nftnl_set_elem_add(set, elem);
  nlh = nftnl_set_nlmsg_build_hdr(buf, NFT_MSG_NEWSET, NFPROTO_IPV4, 0, 4);
  nftnl_set_nlmsg_build_payload(nlh, set);
  if (nftnl_set_nlmsg_parse(nlh, set_back) < 0 ||
      strcmp(nftnl_set_get_str(set_back, NFTNL_SET_NAME), "blocked") != 0 ||
      nftnl_set_get_u32(set_back, NFTNL_SET_KEY_LEN) != sizeof(address)) {
    return fail("set did not round-trip");
  }

  nftnl_rule_free(rule);
  nftnl_rule_free(rule_back);
  nftnl_chain_free(chain);
  nftnl_chain_free(chain_back);
  nftnl_table_free(table);
  nftnl_table_free(table_back);
  nftnl_set_free(set);
  nftnl_set_free(set_back);
  puts("libnftnl: table chain rule set");
  return 0;
}
"""

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libnftnl")
  proof.ensure(fp"{root}/usr/include/libnftnl/rule.h".exists()?, "libnftnl", "missing libnftnl/rule.h")
  proof.ensure(fp"{root}/usr/lib/pkgconfig/libnftnl.pc".exists()?, "libnftnl", "missing libnftnl.pc")
  proof.target_elf(root, p"usr/lib/libnftnl.so.11.8.0", "libnftnl")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"libnftnl ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-libnftnl"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)?
  fp"{tmp}/proof-libnftnl.c".write(program)
  let binary = fp"{tmp}/proof-libnftnl"
  run $cc fp"{tmp}/proof-libnftnl.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lnftnl" "-o" $binary ?
  let libdir = fp"{root}/usr/lib".display()
  let out = run.text LD_LIBRARY_PATH=$libdir $binary ?
  proof.ensure(out.trim() == "libnftnl: table chain rule set", "libnftnl", f"unexpected round-trip output: {out.trim()}")
  print "libnftnl ok: table, base chain, rule, and set round-trip through netlink messages"
}

main(@args)
