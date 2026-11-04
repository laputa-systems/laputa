use pm.proof
use pm.util as pm_util

proc defined_exports(readelf: Path, library: Path) [fs, process, env, error] -> Result[List[Str], Error] {
  var names: List[Str] = []

  for line in (run.text $readelf "--dyn-syms" "-W" $library).lines() {
    let fields = line.fields()

    if fields.len() == 8 and fields[4] == "GLOBAL" and fields[6] != "UND" {
      names += [fields[7].split("@")[0]]
    }
  }

  names
}

proc declared_functions(header: Path) [fs, error] -> Result[List[Str], Error] {
  var names: List[Str] = []

  for line in header.read_text()?.lines() {
    if let [_, name] = rx"""\b(fc_[a-z0-9_]+)\(""".captures(line) {
      if name not in names {
        names += [name]
      }
    }
  }

  names
}

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "rust-fontconfig")
  let version = proof.package_version(root, "rust-fontconfig")?
  let soname = f"librust_fontconfig.so.{version}"
  let library = fp"{root}/usr/lib/{soname}"
  proof.target_elf(root, fp"usr/lib/{soname}", "rust-fontconfig")

  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" "-W" $library
  proof.ensure(f"Library soname: [{soname}]" in dynamic, "proof-rust-fontconfig", f"SONAME is not {soname}")
  proof.ensure("RPATH" not in dynamic and "RUNPATH" not in dynamic, "proof-rust-fontconfig", "library carries a private search path")

  let needed = [line for line in dynamic.lines() if "(NEEDED)" in line]
  proof.ensure(needed.len() == 1 and "[libc.so]" in needed[0], "proof-rust-fontconfig", f"runtime closure is not musl alone: {needed.join(" ")}")

  let link = fp"{root}/usr/lib/librust_fontconfig.so"
  proof.ensure(link.readlink()? == fp"{soname}", "proof-rust-fontconfig", "development link does not name the SONAME file")

  let header = fp"{root}/usr/include/rust-fontconfig/rust_fontconfig.h"
  let exported = defined_exports(readelf, library)?
  let declared = declared_functions(header)?
  let undeclared = [name for name in exported if name not in declared]
  let missing = [name for name in declared if name not in exported]
  proof.ensure(undeclared.is_empty(), "proof-rust-fontconfig", f"exports not in the header: {undeclared.join(" ")}")
  proof.ensure(missing.is_empty(), "proof-rust-fontconfig", f"header functions not exported: {missing.join(" ")}")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "rust-fontconfig ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-rust-fontconfig" {
    fp"{tmp}/fonts.conf".write(f"""<?xml version="1.0"?>
<fontconfig>
  <dir>{root}/usr/share/fonts</dir>
</fontconfig>
""")
    fp"{tmp}/proof.c".write(
      r"""#include <rust_fontconfig.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *what) {
  fprintf(stderr, "rust-fontconfig proof: %s\n", what);
  return 1;
}

static int path_has(FcFontCache cache, const FcFontId *id, const char *suffix) {
  FcFontPath *path = fc_cache_get_font_path(cache, id);
  if (!path) return 0;
  size_t length = strlen(path->path), tail = strlen(suffix);
  int ok = length >= tail && strcmp(path->path + length - tail, suffix) == 0;
  if (!ok) fprintf(stderr, "got %s, expected suffix %s\n", path->path, suffix);
  fc_font_path_free(path);
  return ok;
}

static int run_has(FcFontCache cache, const FcResolvedFontRun *runs, size_t count, const char *text, const char *suffix) {
  for (size_t i = 0; i < count; i++) {
    if (runs[i].text && strstr(runs[i].text, text)) {
      if (!runs[i].has_font) fprintf(stderr, "run [%s] has no font, expected %s\n", runs[i].text, suffix);
      return runs[i].has_font && path_has(cache, &runs[i].font_id, suffix);
    }
  }
  fprintf(stderr, "no run holds %s\n", text);
  for (size_t i = 0; i < count; i++) {
    FcFontPath *path = runs[i].has_font ? fc_cache_get_font_path(cache, &runs[i].font_id) : NULL;
    fprintf(stderr, "run %zu [%s] bytes %zu-%zu font %s\n", i, runs[i].text, runs[i].start_byte, runs[i].end_byte, path ? path->path : "none");
  }
  return 0;
}

static int covers(FcFontCache cache, uint32_t codepoint, const char *suffix) {
  FcPattern *pattern = fc_pattern_new();
  fc_pattern_add_unicode_range(pattern, codepoint, codepoint);
  FcTraceMsg *trace = NULL;
  size_t trace_count = 0;
  FcFontMatch *match = fc_cache_query(cache, pattern, &trace, &trace_count);
  fc_pattern_free(pattern);
  int ok = match && path_has(cache, &match->id, suffix);
  if (match) fc_font_match_free(match);
  fc_trace_free(trace, trace_count);
  return ok;
}

int main(void) {
  if (fc_cache_query(NULL, NULL, NULL, NULL) != NULL) return fail("NULL cache query returned a match");

  FcFontCache cache = fc_cache_build();
  if (!cache) return fail("cache build failed");

  size_t listed = 0;
  FcFontInfo *fonts = fc_cache_list_fonts(cache, &listed);
  if (!fonts || listed < 8) return fail("installed fonts were not discovered");
  int hack = 0, dejavu = 0, cjk = 0;
  for (size_t i = 0; i < listed; i++) {
    if (fonts[i].family && !strcmp(fonts[i].family, "Hack")) hack++;
    if (fonts[i].family && !strcmp(fonts[i].family, "DejaVu Sans")) dejavu++;
    if (fonts[i].family && strstr(fonts[i].family, "Noto Sans CJK")) cjk++;
  }
  fc_font_info_free(fonts, listed);
  if (hack != 4 || dejavu < 1 || cjk < 4) return fail("family inventory is wrong");

  if (!covers(cache, 0x05d0, "/DejaVuSans.ttf") || !covers(cache, 0x0e01, "/NotoSansThai.ttf") || !covers(cache, 0x1f600, "/NotoColorEmoji.ttf")) {
    return fail("coverage query chose the wrong font");
  }

  FcPattern *pattern = fc_pattern_new();
  fc_pattern_set_family(pattern, "Hack");
  fc_pattern_set_bold(pattern, FC_MATCH_TRUE);
  FcTraceMsg *trace = NULL;
  size_t trace_count = 0;
  FcFontMatch *match = fc_cache_query(cache, pattern, &trace, &trace_count);
  fc_pattern_free(pattern);
  if (!match || !path_has(cache, &match->id, "/Hack-Bold.ttf")) return fail("bold Hack query");
  fc_font_match_free(match);
  fc_trace_free(trace, trace_count);

  const char *stack[] = {"Hack", "monospace"};
  trace = NULL;
  trace_count = 0;
  FcFontChain chain = fc_resolve_font_chain(cache, stack, 2, FC_WEIGHT_NORMAL, FC_MATCH_FALSE, FC_MATCH_FALSE, &trace, &trace_count);
  if (!chain) return fail("chain resolution failed");
  fc_trace_free(trace, trace_count);

  const char *text = "A \xd8\xb3 \xe0\xa4\x95 \xe4\xb8\xad";
  size_t run_count = 0;
  FcResolvedFontRun *runs = fc_chain_query_for_text(chain, cache, text, &run_count);
  if (!runs || !run_count) return fail("text query failed");
  int ok = run_has(cache, runs, run_count, "A", "/Hack-Regular.ttf") &&
    run_has(cache, runs, run_count, "\xd8\xb3", "/DejaVuSans.ttf") &&
    run_has(cache, runs, run_count, "\xe0\xa4\x95", "/NotoSansDevanagari.ttf") &&
    run_has(cache, runs, run_count, "\xe4\xb8\xad", "/NotoSansCJK-Regular.ttc");
  fc_resolved_runs_free(runs, run_count);
  if (!ok) return fail("fallback for a codepoint chose the wrong font");

  run_count = 0;
  runs = fc_chain_query_for_text(chain, cache, "\xee\x80\x80", &run_count);
  ok = runs && run_count == 1 && !runs[0].has_font;
  fc_resolved_runs_free(runs, run_count);
  if (!ok) return fail("an uncovered private-use codepoint resolved to a font");
  fc_font_chain_free(chain);

  const FcUnicodeRange scripts[] = {{0x0e00, 0x0e7f}, {0x1f300, 0x1faff}};
  trace = NULL;
  trace_count = 0;
  chain = fc_resolve_font_chain_with_scripts(cache, stack, 2, FC_WEIGHT_NORMAL, FC_MATCH_FALSE, FC_MATCH_FALSE, scripts, 2, &trace, &trace_count);
  if (!chain) return fail("script chain resolution failed");
  fc_trace_free(trace, trace_count);
  run_count = 0;
  runs = fc_chain_query_for_text(chain, cache, "\xe0\xb8\x81 \xf0\x9f\x98\x80", &run_count);
  if (!runs || !run_count) return fail("script chain text query failed");
  ok = run_has(cache, runs, run_count, "\xe0\xb8\x81", "/NotoSansThai.ttf") &&
    run_has(cache, runs, run_count, "\xf0\x9f\x98\x80", "/NotoColorEmoji.ttf");
  fc_resolved_runs_free(runs, run_count);
  if (!ok) return fail("a script chain did not resolve Thai and emoji to their fonts");
  fc_font_chain_free(chain);

  FcFontId unknown = {1, 2};
  if (fc_cache_get_font_path(cache, &unknown) != NULL) return fail("unknown font id resolved");
  fc_cache_free(cache);

  FcFontRegistry registry = fc_registry_new();
  if (!registry) return fail("registry creation failed");
  fc_registry_spawn(registry);
  const char *registry_stack[] = {"Hack", "monospace"};
  const char **stacks[] = {registry_stack};
  size_t counts[] = {2};
  size_t chain_count = 0;
  FcFontChain *chains = fc_registry_request_fonts(registry, stacks, counts, 1, &chain_count);
  if (!chains || chain_count != 1) return fail("registry request failed");
  FcFontCache snapshot = fc_registry_snapshot(registry);
  if (!snapshot) return fail("registry snapshot failed");
  size_t registry_runs = 0;
  FcResolvedFontRun *latin = fc_chain_query_for_text(chains[0], snapshot, "A", &registry_runs);
  ok = latin && registry_runs == 1 && latin[0].has_font && path_has(snapshot, &latin[0].font_id, "/Hack-Regular.ttf");
  fc_resolved_runs_free(latin, registry_runs);
  fc_cache_free(snapshot);
  if (!ok) return fail("registry chain did not resolve Latin to Hack");
  fc_font_chain_free(chains[0]);
  fc_registry_chains_free(chains, chain_count);
  fc_registry_shutdown(registry);
  fc_registry_free(registry);
  return 0;
}
""",
    )
    let pkg_config = fp"{root}/usr/bin/pkgconf"
    let loader = fp"{root}/usr/lib/ld-musl-{(system.uname()?).machine}.so.1"
    let pc_dir = fp"{root}/usr/lib/pkgconfig".display()
    var flags = ""
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display(), PKG_CONFIG_LIBDIR: pc_dir, PKG_CONFIG_PATH: pc_dir, PKG_CONFIG_SYSROOT_DIR: root.display()}) {
      flags = run.text $loader $pkg_config "--cflags" "--libs" "rust-fontconfig"
    }
    proof.ensure(f"{root}/usr/include/rust-fontconfig" in flags and f"{root}/usr/lib" in flags, "proof-rust-fontconfig", "pkg-config paths do not use the relocated root")
    let binary = fp"{tmp}/proof"
    let args = flags.trim().split(" ")
    run $cc fp"{tmp}/proof.c" "-Wall" "-Werror" @args "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display(), FONTCONFIG_FILE: fp"{tmp}/fonts.conf".display(), HOME: tmp.display()}) {
      run $binary
    }
  }
  print "rust-fontconfig ok: SONAME, exports, closure, pkg-config, discovery and codepoint fallback over installed fonts"
}
