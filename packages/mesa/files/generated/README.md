# Mesa generated sources

`mesa-26.2.4-generated.tar.xz` holds every build output that Mesa 26.2.4
produces with Python (Mako/PyYAML), GNU bison, flex, or glslang for the
configuration in [the recipe](../../PKGBUILD.xsh) (`mesa_options`). Laputa's
build world has no Python or glslang. The recipe replaces the generator edges
with archived outputs. Bison and flex outputs remain vendored alongside the
Python outputs. The [parser generation evaluation](EVALUATION.md) records the
measured reason for retaining that policy. The lavapipe Vulkan driver adds
the Vulkan runtime and entry-point tables (Python) and the SPIR-V headers of
its BVH and radix-sort shaders (glslang).

`OUTPUTS` lists the archived paths, relative to the Mesa build directory. The
archive has one top-level directory, `mesa-26.2.4-generated/`, which PM strips
when it stages the archive as `generated/`.

The set is exactly what this configuration builds: a Mesa upgrade or an option
change means regenerating it, and the recipe fails if a vendored file no longer
matches a build edge. Most outputs depend only on the Mesa version; the GL API
tables (`src/mesa/glapi/...`) also depend on the enabled APIs, and
`src/util/driconf_static.h` on the enabled drivers. The recipe drops
lavapipe's uninstalled developer ICD manifest, which names the build
directory and host CPU, so the set is the same on every architecture.

## Regenerating

Regenerate in an `alpine:3.22` container (musl, like Laputa) with
python3, glslang, GNU bison, flex, ninja, pkgconf, and a C/C++ compiler from
apk, and a pkg-config sysroot mounted at `/sysroot` holding Laputa's
`libdrm`, `wayland-dev`, `wayland-libs-client`, `wayland-protocols`,
`libffi`, `expat`, and `llvm-static` payloads. The configure step needs their
`.pc` files and llvm-static's `llvm-config`; nothing is compiled:

```sh
apk add --no-cache python3 bison flex ninja glslang pkgconf gcc g++ musl-dev
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install meson==1.12.1 mako==1.4.3 pyyaml==6.0.3 packaging==26.3
tar xJf mesa-26.2.4.tar.xz -C /tmp
cd /tmp/mesa-26.2.4
export PATH="/tmp/venv/bin:/sysroot/usr/lib/llvm-static/bin:$PATH"
PKG_CONFIG_SYSROOT_DIR=/sysroot \
PKG_CONFIG_LIBDIR=/sysroot/usr/lib/pkgconfig:/sysroot/usr/share/pkgconfig \
  meson setup build -Dprefix=/usr -Dlibdir=lib <every option in mesa_options>
ninja -C build $(cat /path/to/packages/mesa/files/generated/OUTPUTS)
```

Do not put the sysroot's libraries on `LD_LIBRARY_PATH`: Python's `pyexpat`
then loads Laputa's `libexpat` and fails to import.

To find the full set after an upgrade or option change, list the custom
build edges whose command runs Python, bison, flex, or glslang, then drop the
lavapipe devenv manifest. The recipe's own build prints the same set: its
`mesa: staged` line names the vendored outputs it found and every generator
edge with no archived output.

Pack the outputs reproducibly (sorted, zero mtimes and owners) by running this
in the build directory with a copy of `OUTPUTS` beside it:

```python
import io, lzma, tarfile
top = "mesa-26.2.4-generated"
paths = sorted(p.strip() for p in open("OUTPUTS") if p.strip())
dirs = {"/".join([top] + p.split("/")[:i]) for p in paths for i in range(p.count("/") + 1)}
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
    for d in sorted(dirs):
        info = tarfile.TarInfo(d)
        info.type, info.mode = tarfile.DIRTYPE, 0o755
        tar.addfile(info)
    for p in paths:
        data = open(p, "rb").read()
        info = tarfile.TarInfo(f"{top}/{p}")
        info.size, info.mode = len(data), 0o644
        tar.addfile(info, io.BytesIO(data))
open(f"{top}.tar.xz", "wb").write(lzma.compress(buf.getvalue(), preset=9 | lzma.PRESET_EXTREME))
```

The current archive (138 outputs) was generated with meson 1.12.1,
Mako 1.4.3, PyYAML 6.0.3, packaging 26.3, Python 3.12, GNU bison 3.8.2,
flex 2.6.4, and glslang 15.2.0. The 81 outputs of the previous configuration
are byte-identical to those its Python 3.14 run produced, apart from
`driconf_static.h`, which gains the `lvp` device. Gluon configured from
the recipe-patched tree finds exactly these 138 generator edges. Then update
the archive's sha256 in `PKGBUILD.xsh`.
