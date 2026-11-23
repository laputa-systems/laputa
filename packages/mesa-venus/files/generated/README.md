# Mesa Venus generated sources

`mesa-venus-26.2.4-generated.tar.xz` holds the 55 build outputs that Mesa 26.2.4
produces with Python (Mako/PyYAML), GNU bison or flex for the option set in
[the recipe](../../PKGBUILD.xsh). The Laputa build world has no Python, so the
recipe replaces those generator edges with these outputs, as `packages/mesa`
does for its own set. `OUTPUTS` lists the archived paths relative to the build
directory; the archive has one top-level directory that PM strips when it stages
it as `generated/`.

Regenerate in an `alpine:3.22` container with python3, bison, flex, ninja,
glslang, pkgconf, gcc, g++, musl-dev, libdrm-dev, wayland-dev,
wayland-protocols and linux-headers from apk, and meson 1.12.1, mako 1.4.3,
pyyaml 6.0.3 and packaging 26.3 in a venv. Configure Mesa with the `mesa_options`
of the recipe, then list the custom build edges whose command runs Python,
bison or flex and drop meson's own `meson-internal__*` targets and the
uninstalled `virtio_devenv_icd.*.json` manifest, which names the build directory
and host CPU. Build those outputs with `ninja` and pack them with the sorted,
zero-mtime archive script in `packages/mesa/files/generated/README.md`, with the
top directory `mesa-venus-26.2.4-generated`. Then update the archive's sha256 in
`PKGBUILD.xsh`. The recipe's `mesa: staged` line names any generator edge with no
archived output.
