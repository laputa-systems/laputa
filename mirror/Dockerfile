# syntax=docker/dockerfile:1
FROM alpine:3.24.1 AS builder

RUN apk add --no-cache musl-dev libgcc ca-certificates

ADD --checksum=sha256:c43f18f143cc17f49814b6c5dda8a1122d17b6bcdff9848b6f77e97b33026dfe https://github.com/laputa-systems/llvm-prebuilt-musl/releases/download/llvm-musl-23.1.5-dc0d9b9/clang+llvm-23.1.5-x86_64-linux-musl.tar.xz /tmp/llvm.tar.xz
RUN mkdir -p /opt/llvm-musl \
    && tar xf /tmp/llvm.tar.xz -C /opt/llvm-musl --strip-components=1 \
    && rm /tmp/llvm.tar.xz

ADD https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-musl/rustup-init /rustup-init
RUN chmod +x /rustup-init \
    && /rustup-init -y --default-toolchain none \
    && rm /rustup-init

ENV PATH="/opt/llvm-musl/bin:/root/.cargo/bin:$PATH" \
    CC="/opt/llvm-musl/bin/clang" \
    AR="/opt/llvm-musl/bin/llvm-ar" \
    RANLIB="/opt/llvm-musl/bin/llvm-ranlib" \
    CC_X86_64_UNKNOWN_LINUX_MUSL="/opt/llvm-musl/bin/clang" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="rust-lld" \
    CFLAGS_x86_64_unknown_linux_musl="--target=x86_64-unknown-linux-musl -I/usr/include"

# The local toolchain pin is for native development; pin the MUSL build to a
# nightly that publishes the cross-target component and invoke it explicitly.
ARG MUSL_TOOLCHAIN=nightly-2026-04-20
RUN rustup toolchain install "$MUSL_TOOLCHAIN" \
    --target x86_64-unknown-linux-musl

# Host proc-macro crates link dynamically while Cargo is building. The musl
# rustup sysroot does not always expose the Alpine libc and libgcc_s names
# that rust-lld searches for, so install stable symlinks in the host target
# libdir.
RUN host_libdir="$(rustc --print target-libdir)" \
    && ln -sf /usr/lib/libgcc_s.so.1 "${host_libdir}/libgcc_s.so" \
    && ln -sf /usr/lib/libgcc_s.so.1 "${host_libdir}/libgcc_s.so.1" \
    && ln -sf /usr/lib/libc.so "${host_libdir}/libc.so"

WORKDIR /build
COPY . .

RUN cargo +"$MUSL_TOOLCHAIN" build --locked --bins --target x86_64-unknown-linux-musl --release

FROM scratch
# Build-only artifact image: `mirror-build-x86_64-musl` copies the static
# binary out of this stage with `--output type=local`. It is never run, so
# it carries no CA store. Production runs on the Ubuntu host and verifies
# HTTPS against the host system trust store; no bundle is shipped here.
COPY --from=builder /build/target/x86_64-unknown-linux-musl/release/laputa-mirror /
