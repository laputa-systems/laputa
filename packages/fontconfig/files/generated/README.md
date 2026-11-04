# Regenerate Fontconfig headers

The archive contains the generated headers used by the Fontconfig 2.18.3
recipe. The package build stages them because its build root has no Python or
gperf. Regenerate them when the upstream version or generator inputs change.

Use Muon 0.7.0, Python 3.15.1, GNU gperf 3.3, Samurai, a C compiler, and
pkg-config with FreeType and Expat available. Extract the verified upstream
archive under `.work/tmp` and run these commands from the extracted source:

```sh
muon setup -Dprefix=/usr -Dlibdir=lib -Dsysconfdir=/etc -Dlocalstatedir=/var \
  -Ddefault_library=shared -Dxml-backend=expat -Dtools=disabled -Ddoc=disabled \
  -Dnls=disabled -Dtests=disabled -Dtests-external-fonts=disabled \
  -Dcache-build=disabled build
samu -C build fcalias.h fcaliastail.h fcftalias.h fcftaliastail.h \
  fc-case/fccase.h fc-lang/fclang.h fc-const/fcconst.h \
  fc-genericfamily/fcgenericfamily.h src/fcobjshash.h
```

Run this command from the extracted source to pack the generated headers:

```sh
python3 - <<'PY'
import io, lzma, pathlib, tarfile
paths = ['fcalias.h', 'fcaliastail.h', 'fcftalias.h', 'fcftaliastail.h',
         'fc-case/fccase.h', 'fc-lang/fclang.h', 'fc-const/fcconst.h',
         'fc-genericfamily/fcgenericfamily.h', 'src/fcobjshash.h']
top = 'fontconfig-2.18.3-generated'
dirs = {top}
for name in paths:
    parts = name.split('/')
    dirs.update('/'.join([top] + parts[:i]) for i in range(1, len(parts)))
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as tar:
    for name in sorted(dirs):
        info = tarfile.TarInfo(name)
        info.type, info.mode = tarfile.DIRTYPE, 0o755
        tar.addfile(info)
    for name in sorted(paths):
        data = (pathlib.Path('build') / name).read_bytes()
        info = tarfile.TarInfo(f'{top}/{name}')
        info.mode, info.size = 0o644, len(data)
        tar.addfile(info, io.BytesIO(data))
pathlib.Path(f'{top}.tar.xz').write_bytes(lzma.compress(buf.getvalue(), preset=9))
PY
```

Compare the generated headers with the previous archive, update the archive in
this directory, and update its checksum in the recipe. Run the package build
and proof on each supported architecture.
