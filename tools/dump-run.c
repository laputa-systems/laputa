/* Test-only behavioral oracle (lives in .work, never in the repo).
 * Compiles the REAL mdevd.c with its main renamed, then drives its static
 * parse + match code in dry-run mode on scripted (config, event) pairs.
 * Usage: dump-run CONFFILE EVENTFILE
 * EVENTFILE: lines NAME=VALUE (e.g. ACTION=add DEVPATH=/x DEVNAME=foo ...).
 * Prints the reference "dry run: ..." transcript to stdout.
 */
#define main mdevd_main_disabled
#include "mdevd_impl.c"
#undef main

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fprintf(stderr, "usage: dump-run CONFFILE EVENTFILE\n");
    return 100;
  }
  PROG = "dump-run";
  dryrun = 1;
  verbosity = 0;
  slashsys = "/nonexistent-sys";
  {
    const char *slashsys_env = getenv("DUMP_SLASHSYS");
    if (slashsys_env && slashsys_env[0]) slashsys = slashsys_env;
  }
  root_maj = (unsigned int)-1;
  root_min = (unsigned int)-1;
  {
    const char *verbosity_env = getenv("DUMP_VERBOSE");
    if (verbosity_env && verbosity_env[0]) verbosity = 2;
  }

  unsigned short scriptlen = 0, envmatchlen = 0;
  static char storage[CONFBUFSIZE];
  ssize_t len = openreadnclose(argv[1], storage, CONFBUFSIZE - 1);
  if (len < 0) {
    fprintf(stderr, "dump-run: cannot read %s\n", argv[1]);
    return 111;
  }
  storage[len++] = 0;
  /* NOTE: first/second pass die (exit 2) on syntax error, like -N. */
  script_firstpass(storage, &scriptlen, &envmatchlen);
  {
    struct envmatch_s envmatch[envmatchlen ? envmatchlen : 1];
    scriptelem script[scriptlen + 1];
    memset(script, 0, scriptlen * sizeof(scriptelem));
    script[scriptlen++] = scriptelem_catchall;
    script_secondpass(storage, script, envmatch);

    /* Rule dump: index devmatch-type envbase envlen cont uid gid mode movetype cmdtype */
    for (unsigned short k = 0; k < scriptlen; k++) {
      printf("rule %u dev=%u envbase=%u envlen=%u cont=%u uid=%u gid=%u mode=%o move=%u cmd=%u",
             k, script[k].devmatchtype, script[k].envmatchs,
             script[k].envmatchlen, script[k].flagcont,
             (unsigned)script[k].uid, (unsigned)script[k].gid,
             script[k].mode, script[k].movetype, script[k].cmdtype);
      if (script[k].devmatchtype == DEVMATCH_MAJMIN)
        printf(" maj=%u lo=%u hi=%u", script[k].devmatch.majmin.maj,
               script[k].devmatch.majmin.minlo, script[k].devmatch.majmin.minhi);
      printf("\n");
      for (unsigned n = 0; n < script[k].envmatchlen; n++) {
        /* var name survives at its offset (zero-terminated by the passes). */
        printf("  env %s\n", storage + envmatch[script[k].envmatchs + n].var);
      }
      if (script[k].movetype == MOVEINFO_MOVE || script[k].movetype == MOVEINFO_MOVEANDLINK)
        printf("  path %s\n", storage + script[k].movepath);
      if (script[k].cmdtype != ACTION_NONE)
        printf("  cmd mask=%u excl=%u %s\n", script[k].cmdtype,
               script[k].flagexecline, storage + script[k].command);
    }

    /* Event transcript. */
    FILE *f = fopen(argv[2], "r");
    if (!f) {
      fprintf(stderr, "dump-run: cannot read %s\n", argv[2]);
      return 111;
    }
    struct uevent_s event = UEVENT_ZERO;
    udata ud = UDATA_ZERO;
    size_t off = 0, v = 0;
    /* vars[0] is the header, like a real netlink record. */
    strcpy(event.buf, "add@/dump");
    off = strlen(event.buf) + 1;
    event.vars[v++] = 0;
    char line[UEVENT_MAX_SIZE];
    while (fgets(line, sizeof line, f)) {
      size_t ln = strlen(line);
      while (ln && (line[ln - 1] == '\n' || line[ln - 1] == '\r')) line[--ln] = 0;
      if (!ln) continue;
      if (off + ln + 1 >= sizeof event.buf) {
        fprintf(stderr, "dump-run: event too large\n");
        return 111;
      }
      event.vars[v++] = (unsigned short)off;
      memcpy(event.buf + off, line, ln + 1);
      off += ln + 1;
    }
    fclose(f);
    event.len = (unsigned short)off;
    event.varn = (unsigned short)v;
    ud.i = 0;
    on_event(&event, script, scriptlen, storage, envmatch, &ud);
    script_free(script, scriptlen, envmatch, envmatchlen);
  }
  return 0;
}
