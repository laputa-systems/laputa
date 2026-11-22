##! XSH module `zlib-rs` package proof.
use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "zlib-rs")
  let library = fp"{root}/usr/lib/zlib-rs/libz.so.1"
  proof.target_elf(root, p"usr/lib/zlib-rs/libz.so.1", "zlib-rs")

  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" "-W" $library
  proof.ensure("Library soname: [libz.so.1]" in dynamic, "proof-zlib-rs", "SONAME is not libz.so.1")
  proof.ensure("RPATH" not in dynamic and "RUNPATH" not in dynamic, "proof-zlib-rs", "library carries a private search path")

  let needed = [line for line in dynamic.lines() if "(NEEDED)" in line]
  proof.ensure(needed.len() == 1 and "[libc.so]" in needed[0], "proof-zlib-rs", f"runtime closure is not musl alone: {needed.join(" ")}")

  let link = fp"{root}/usr/lib/zlib-rs/libz.so"
  proof.ensure(link.readlink()? == fp"libz.so.1", "proof-zlib-rs", "development link does not name the SONAME file")

  let exported = run.text $readelf "--dyn-syms" "-W" $library
  for symbol in ["deflateInit2_", "inflateInit2_", "compress2", "uncompress2", "crc32", "adler32", "gzopen", "gzread", "gzwrite", "inflateBackInit_", "zlibVersion"] {
    proof.ensure(f" {symbol}@@" in exported or f" {symbol}\n" in f"{exported}\n", "proof-zlib-rs", f"missing export {symbol}")
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "zlib-rs ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-zlib-rs" {
    fp"{tmp}/proof.c".write(
      """#include <string.h>
#include <zlib.h>

int main(void) {
  const unsigned char input[] = "laputa zlib-rs proof";
  unsigned char compressed[128];
  unsigned char output[128];
  uLongf compressed_len = sizeof(compressed);
  uLongf output_len = sizeof(output);

  if (compress(compressed, &compressed_len, input, strlen((const char *)input) + 1) != Z_OK) {
    return 1;
  }
  if (uncompress(output, &output_len, compressed, compressed_len) != Z_OK) {
    return 2;
  }
  return strcmp((const char *)output, (const char *)input) == 0 ? 0 : 3;
}
""",
    )

    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include/zlib-rs" f"-L{root}/usr/lib/zlib-rs" "-lz" "-o" $binary

    env ({
      LD_LIBRARY_PATH: fp"{root}/usr/lib/zlib-rs".display(),
    }) {
      run $binary
    }
  }

  print "zlib-rs ok"
}
