ARG SEED_IMAGE
FROM ${SEED_IMAGE} AS seed
COPY probe.c /probe.c
COPY bin/mold /bin/mold
RUN ["/usr/bin/clang", "-fuse-ld=/bin/mold", "-static", "-nostdlib", "/usr/lib/crt1.o", "/usr/lib/crti.o", "/probe.c", "/usr/lib/libc.a", "/usr/lib/crtn.o", "-o", "/probe"]

FROM scratch
COPY --from=seed /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
COPY --from=seed /lib/libc.musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1
COPY --from=seed /usr/lib/llvm23 /usr/lib/llvm23
COPY --from=seed /usr/include /usr/include
COPY --from=seed /usr/lib/libc.a /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/
COPY --from=seed /usr/lib/libLLVM.so.23.1 /usr/lib/libstdc++.so.6* /usr/lib/libgcc_s.so.1 /usr/lib/libffi.so.8* /usr/lib/libz.so.1* /usr/lib/libzstd.so.1* /usr/lib/libxml2.so.2* /usr/lib/liblzma.so.5* /usr/lib/libbfd-2.45.1.so /usr/lib/libctf.so.0* /usr/lib/libctf-nobfd.so.0* /usr/lib/libjansson.so.4* /usr/lib/libsframe.so.2* /usr/lib/
COPY --from=seed /usr/bin/ld /usr/bin/ld
COPY --from=seed /usr/bin/readelf /usr/bin/readelf
COPY links/ /
COPY --from=seed /root/.rustup/toolchains/nightly-2026-09-15-x86_64-unknown-linux-musl /seed/rust
COPY --from=seed /probe /seed/probe
COPY bin/ /bin/
COPY core/ /usr/lib/xsh/core/
COPY pm.xsh /pm/pm.xsh
COPY pm/ /pm/pm/
COPY cohort/ /cohort/
ENV PATH=/bin:/usr/lib/xsh/core:/usr/bin
ENV XSH_MODULE_PATH=/pm
ENV HOME=/scratch/home
ENV HOSTNAME=closed-build
ENV TMPDIR=/scratch
ENV LANG=C
ENV LC_ALL=C
ENV TZ=UTC
ENV MAKEFLAGS=-j1
ENV KACHE_CACHE_DIR=/scratch/kache
ENV KACHE_RUNTIME_DIR=/scratch/kache-runtime
ENV KACHE_SOCKET_PATH=/scratch/kache-runtime/daemon.sock
ENV KACHE_LOCAL_ONLY=1
WORKDIR /cohort
USER 65534:65534
ENTRYPOINT ["/bin/xsh", "/cohort/build.xsh", "--"]
