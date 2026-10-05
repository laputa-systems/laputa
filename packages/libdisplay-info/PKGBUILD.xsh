##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env

## Exported declaration `name`.
export const name = "libdisplay-info"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "0.4.0"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "hwdata"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "muon", "samurai", "pkgconf", "hwdata"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/VERSION/downloads/libdisplay-info-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "43b180baa143e2035654759d84e2b2f5ee77d5fe817c423838c7fe59c0d68459",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/libdisplay-info/cta-vic.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/cta.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/cvt.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/displayid.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/displayid2.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/dmt.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/edid.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/gtf.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/hdmi-vic.h",
    kind: "file",
  },
  {
    path: p"usr/include/libdisplay-info/info.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libdisplay-info.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libdisplay-info.so.0.4.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/libdisplay-info.so.4",
    kind: "symlink",
  },
  {
    path: p"usr/lib/pkgconfig/libdisplay-info.pc",
    kind: "file",
  },
]

# Port of tool/gen-search-table.py, which turns hwdata's pnp.ids into the
# PNP ID lookup switch. The output matches the script's except in escaping:
# the script escapes each non-alphanumeric character by its code point, which
# for a non-ASCII character yields an octal escape C reads as the wrong bytes.
# This port escapes every byte outside [A-Za-z0-9 .,] instead, so names stay
# valid UTF-8, and `?` is still escaped, so no trigraph forms.
pure c_escaped(text: Str) -> Str {
  var out = ""
  var index = 0

  while index < text.byte_len() {
    let byte = text.byte_at(index) ?? 0
    let plain = (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 32 or byte == 44 or byte == 46

    if plain {
      out = f"{out}{text.byte_slice(index, 1)}"
    } else {
      out = f"{out}\\{byte / 64}{byte / 8 % 8}{byte % 8}"
    }

    index += 1
  }

  out
}

## The PNP ID lookup C source for the text of hwdata's pnp.ids: one switch
## case per three-character ID, keyed by the ID's bytes, the last name
## listed for an ID winning.
export pure pnp_id_table_source(pnp_ids: Str) -> Str {
  var names: Map[Str] = {}

  for line in pnp_ids.split("\n") {
    if let [_, id, display_name] = rx"^\s*(\S+)\s+(.*)$".captures(line) {
      if id.count_chars() == 3 {
        names[id] = c_escaped(display_name.trim())
      }
    }
  }

  let cases = collect {
    for id in names.keys() |> sort {
      let key = (id.byte_at(0) ?? 0) * 65536 + (id.byte_at(1) ?? 0) * 256 + (id.byte_at(2) ?? 0)
      yield f"    case {key}: return \"{names.get(id) ?? ""}\";"
    }
  }

  let case_text = cases.join("\n")

  f"""

#include <string.h>
#include <stdint.h>

const char *
pnp_id_table(const char *key);

const char *
pnp_id_table(const char *key)
{{
    size_t len = strlen(key);
    size_t i;
    uint32_t u = 0;

    if (len > 4)
        return NULL;

    for (i = 0; i < len; i++)
        u = (u << 8) | (uint8_t)key[i];

    switch (u) {{
{case_text}

    default:
        return NULL;
    }}
}}
"""
}

proc write_pnp_table(root: Str) {
  let pnp = fp"{root}/usr/share/hwdata/pnp.ids"
  p"pnp-id-table.c".write(pnp_id_table_source(pnp.read_text()?))
}

proc patch_generators(root: Str) {
  write_pnp_table(root)
  let meson_path = p"meson.build"
  var text = meson_path.read_text()?

  text = text.replace(
    """gen_search_table = find_program('tool/gen-search-table.py')
pnp_id_table = custom_target(
	'pnp-id-table.c',
	command: [ gen_search_table, pnp_ids, '@OUTPUT@', 'pnp_id_table' ],
	output: 'pnp-id-table.c',
)
""",
    with: """pnp_id_table = files('pnp-id-table.c')
""",
  )

  text = text.replace(
    """
subdir('di-edid-decode')
subdir('test')
""",
    with: "\n",
  )

  text = text.replace(
    "math = cc.find_library('m', required: false)",
    with: "math = declare_dependency(link_args: ['-lm'])",
  )
  meson_path.write(text)
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  let root = e"LAPUTA_ROOT" ?? "/"
  patch_generators(root)

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() "-Ddefault_library=shared" "build"
    run $muon "-C" "build" samu $jobs_flag

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install
    }
  }?
}
