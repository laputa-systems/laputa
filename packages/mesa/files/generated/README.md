# Mesa generated sources

`mesa-26.2.4-generated.tar.xz` holds every build output that Mesa 26.2.4
produces with Python (Mako/PyYAML), GNU bison, or flex for the configuration
in `../../PKGBUILD.xsh` (`mesa_options`). Laputa's build world has no Python,
and its bison and flex cannot process these grammars, so the recipe drops the
build edges for these outputs and copies them from this archive instead.

`OUTPUTS` lists the archived paths, relative to the Mesa build directory. The
archive has one top-level directory, `mesa-26.2.4-generated/`, which PM strips
when it stages the archive as `generated/`.

The set is exactly what this configuration builds: a Mesa upgrade or an option
change means regenerating it, and the recipe fails if a vendored file no longer
matches a build edge. Most outputs depend only on the Mesa version; the GL API
tables (`src/mesa/glapi/...`) also depend on the enabled APIs.

## Regenerating

On a host with python3 (3.10 or newer), GNU bison, flex, ninja, and a
pkg-config sysroot holding Laputa's `libdrm`, `wayland-dev`,
`wayland-libs-client`, `wayland-protocols`, `libffi`, and `expat` payloads
(the configure step needs their `.pc` files; nothing is compiled):

```sh
python3 -m venv /tmp/mesa-venv
/tmp/mesa-venv/bin/pip install meson mako pyyaml packaging
tar xf mesa-26.2.4.tar.xz && cd mesa-26.2.4
PKG_CONFIG_SYSROOT_DIR=$SYSROOT \
PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig \
PATH=/tmp/mesa-venv/bin:$PATH \
  meson setup build <every option in mesa_options>
ninja -C build $(cat /path/to/packages/mesa/files/generated/OUTPUTS)
```

To find the full set after an upgrade, list the build edges whose command
runs Python, bison, or flex and that the default target needs: build
everything with `ninja -C build`, then keep those outputs that exist.

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

The current archive was generated with meson 1.12.1, Mako 1.4.3,
PyYAML 6.0.3, packaging 26.3, Python 3.12, GNU bison 3.8.2, and flex 2.6.4.
muon 0.5.0 configured from the recipe-patched tree produces byte-identical
outputs. Then update the archive's sha256 in `PKGBUILD.xsh`.
