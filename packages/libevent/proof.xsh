use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libevent")
  proof.target_elf(root, p"usr/lib/libevent_core-2.1.so.7", "libevent")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "libevent ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-libevent"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()

  # tmux drives its whole client and server through an event_base, a pipe
  # read event, and timers. Both events here are one-shot, so dispatch returns
  # once each has fired.
  fp"{tmp}/proof-libevent.c".write(
    """#include <string.h>
#include <unistd.h>
#include <event2/buffer.h>
#include <event2/event.h>

static int timer_fired;
static char received[32];

static void on_timer(evutil_socket_t fd, short what, void *arg) {
  (void)fd; (void)what; (void)arg;
  timer_fired = 1;
}

static void on_read(evutil_socket_t fd, short what, void *arg) {
  (void)what; (void)arg;
  ssize_t n = read(fd, received, sizeof(received) - 1);
  if (n > 0) received[n] = 0;
}

int main(void) {
  int fds[2];
  struct event_base *base = event_base_new();
  if (base == NULL || pipe(fds) != 0) return 1;
  struct timeval soon = {0, 1000};
  struct event *timer = evtimer_new(base, on_timer, NULL);
  struct event *reader = event_new(base, fds[0], EV_READ, on_read, NULL);
  if (timer == NULL || reader == NULL) return 2;
  evtimer_add(timer, &soon);
  event_add(reader, NULL);
  if (write(fds[1], "laputa", 6) != 6) return 3;
  if (event_base_dispatch(base) < 0) return 4;
  if (!timer_fired || strcmp(received, "laputa") != 0) return 5;
  struct evbuffer *buf = evbuffer_new();
  evbuffer_add_printf(buf, "%s-%d", "event", 21);
  if (evbuffer_get_length(buf) != 8) return 6;
  evbuffer_free(buf);
  event_free(timer);
  event_free(reader);
  event_base_free(base);
  return strncmp(event_get_version(), "2.1.", 4) == 0 ? 0 : 7;
}
""",
  )

  let binary = fp"{tmp}/proof-libevent"
  run $cc fp"{tmp}/proof-libevent.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-levent_core" "-o" $binary

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
  }) {
    run $binary
  }

  print "libevent ok: event loop, pipe read, timer, evbuffer"
}

main(@args)
