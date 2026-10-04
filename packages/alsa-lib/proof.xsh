##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# Build containers and proof roots have no sound card, so the program drives
# libasound's software PCMs. It parses a config from memory with
# snd_config_load, plays through the "null" PCM that the installed alsa.conf
# defines, then through a plug PCM from the loaded config that converts the
# client's 48 kHz S16 stream into a 44.1 kHz S32 null slave (the plug, linear,
# and rate plugins). Each stream reports its state before, during, and after
# the writes.
const program = r"""#include <stdio.h>
#include <string.h>
#include <alsa/asoundlib.h>

#define CHECK(expr) do { int err_ = (expr); if (err_ < 0) { fprintf(stderr, "%s: %s\n", #expr, snd_strerror(err_)); return 1; } } while (0)

static const char proof_conf[] =
  "proof.rate 48000\n"
  "proof.label \"laputa\"\n"
  "pcm.proof { type plug slave { pcm { type null } format S32_LE rate 44100 } }\n";

static int play(snd_pcm_t *pcm, const char *label) {
  snd_pcm_hw_params_t *hw;
  unsigned int rate = 48000;
  short frames[2 * 480];
  long written = 0;
  snd_pcm_hw_params_alloca(&hw);
  CHECK(snd_pcm_hw_params_any(pcm, hw));
  CHECK(snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED));
  CHECK(snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE));
  CHECK(snd_pcm_hw_params_set_channels(pcm, hw, 2));
  CHECK(snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, 0));
  CHECK(snd_pcm_hw_params(pcm, hw));
  if (rate != 48000) {
    fprintf(stderr, "%s: negotiated rate %u\n", label, rate);
    return 1;
  }
  const char *before = snd_pcm_state_name(snd_pcm_state(pcm));
  memset(frames, 0, sizeof(frames));
  for (int i = 0; i < 10; i++) {
    snd_pcm_sframes_t n = snd_pcm_writei(pcm, frames, 480);
    if (n < 0) {
      fprintf(stderr, "%s: writei: %s\n", label, snd_strerror((int)n));
      return 1;
    }
    written += n;
  }
  const char *during = snd_pcm_state_name(snd_pcm_state(pcm));
  CHECK(snd_pcm_drain(pcm));
  const char *after = snd_pcm_state_name(snd_pcm_state(pcm));
  printf("%s %s %s %s %s %ld\n", label, snd_pcm_type_name(snd_pcm_type(pcm)), before, during, after, written);
  return 0;
}

int main(void) {
  snd_config_t *top, *node;
  snd_input_t *in;
  long rate;
  const char *label;
  snd_pcm_t *pcm;

  CHECK(snd_config_top(&top));
  CHECK(snd_input_buffer_open(&in, proof_conf, -1));
  CHECK(snd_config_load(top, in));
  snd_input_close(in);
  CHECK(snd_config_search(top, "proof.rate", &node));
  CHECK(snd_config_get_integer(node, &rate));
  CHECK(snd_config_search(top, "proof.label", &node));
  CHECK(snd_config_get_string(node, &label));
  printf("config %s %ld\n", label, rate);

  CHECK(snd_pcm_open(&pcm, "null", SND_PCM_STREAM_PLAYBACK, 0));
  if (play(pcm, "null")) return 1;
  CHECK(snd_pcm_close(pcm));

  CHECK(snd_pcm_open_lconf(&pcm, "proof", SND_PCM_STREAM_PLAYBACK, 0, top));
  if (play(pcm, "proof")) return 1;
  CHECK(snd_pcm_close(pcm));
  snd_config_delete(top);
  printf("version %s\n", snd_asoundlib_version());
  return 0;
}
"""

const expected = """config laputa 48000
null NULL PREPARED RUNNING SETUP 4800
proof PLUG PREPARED RUNNING SETUP 4800
version 1.2.16.1"""

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "alsa-lib")?

  for lib in ["libasound", "libatopology"] {
    let so = fp"usr/lib/{lib}.so.2.0.0"
    proof.target_elf(root, so, "alsa-lib")?
    let readelf = proof.readelf_tool()?
    let dynamic = run.text $readelf "-d" fp"{root}/{so}" ?
    proof.ensure(f"[{lib}.so.2]" in dynamic, "proof-alsa-lib", f"{lib} has no {lib}.so.2 SONAME")?
  }

  # pkg-config expands ${name} references, so consumers get real paths.
  let pc = fp"{root}/usr/lib/pkgconfig/alsa.pc".read_text()?
  proof.ensure(r"exec_prefix=${prefix}" in pc, "proof-alsa-lib", "alsa.pc does not derive exec_prefix from prefix")?
  proof.ensure(r"Cflags: -I${includedir}" in pc, "proof-alsa-lib", "alsa.pc does not reference includedir")?
  proof.ensure(r"Libs: -L${libdir} -lasound" in pc, "proof-alsa-lib", "alsa.pc does not reference libdir")?

  # The configuration tree libasound reads from ALSA_CONFIG_DIR.
  let share = fp"{root}/usr/share/alsa"

  for conf in [p"alsa.conf", p"pcm/default.conf", p"pcm/dmix.conf", p"ctl/default.conf", p"cards/HDA-Intel.conf", p"cards/aliases.conf"] {
    proof.ensure(fs.exists(fp"{share}/{conf}")?, "proof-alsa-lib", f"missing /usr/share/alsa/{conf}")?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"alsa-lib ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-alsa-lib"
  fs.remove(tmp, missing_ok: true)?
  fs.mkdir(tmp, true)?
  defer fs.remove(tmp, missing_ok: true)?
  fs.write(fp"{tmp}/proof-alsa-lib.c", program)?
  let binary = fp"{tmp}/proof-alsa-lib"
  run $cc fp"{tmp}/proof-alsa-lib.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lasound" "-o" $binary ?

  # ALSA_CONFIG_DIR points libasound at the proof root's tree instead of the
  # compiled-in /usr/share/alsa.
  let out = env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
    ALSA_CONFIG_DIR: share.display(),
  }) {
    run.text $binary ?
  }?

  proof.ensure(out.trim() == expected, "proof-alsa-lib", f"unexpected software PCM run:\n{out.trim()}")?
  print "alsa-lib ok: snd_config_load parsed, null and plug->null PCMs ran PREPARED -> RUNNING -> SETUP"
}

main(@args)?
