# Single entry point for the Laputa monorepo.
#
# XSH is co-developed in its own checkout at XSH_ROOT. Host tools default to
# its release binaries; PM loads PKGBUILD modules and spawns XSH runners at
# runtime, and those resolve `pm.*` imports only through XSH_MODULE_PATH,
# which xsht-config.ini cannot provide.
#
# A Linux host needs no Rust toolchain: when XSH_ROOT has no release build,
# the host tools are the static musl binaries `make host-xsh` builds in XSH's
# own `xsh-test` image under .out/host/<host arch>/, and `make mirror` runs a
# mirror built the same way.

XSH_ROOT ?= ../xsh
XSH_ROOT_ABS := $(abspath $(XSH_ROOT))

# The machine running make. Docker images and host tools follow it, and ARCH
# (the seed and package target) defaults to it: aarch64 on Apple Silicon and
# arm64 Linux, x86_64 on an amd64 Linux host.
HOST_OS := $(shell uname -s)
HOST_ARCH := $(patsubst arm64,aarch64,$(patsubst amd64,x86_64,$(shell uname -m)))
HOST_TRIPLE := $(HOST_ARCH)-unknown-linux-musl
HOST_DOCKER_PLATFORM := linux/$(if $(filter x86_64,$(HOST_ARCH)),amd64,arm64)
HOST_TOOLS_DIR := $(CURDIR)/.out/host/$(HOST_ARCH)

# Linux hosts run the mirror built by `make host-mirror` (its crates come from
# `make fetch`); macOS developers run it through their cargo.
ifeq ($(HOST_OS),Linux)
FETCH_HOST_MIRROR := fetch-mirror
MIRROR_SERVER_DEPS := host-mirror
MIRROR_SERVER = "$(HOST_TOOLS_DIR)/laputa-mirror"
else
FETCH_HOST_MIRROR :=
MIRROR_SERVER_DEPS :=
MIRROR_SERVER = cd $(MIRROR) && $(CARGO) run -j $(CARGO_JOBS) --locked --bin laputa-mirror --
endif

XSH_RELEASE_DIR := $(XSH_ROOT_ABS)/target/release
ifeq ($(HOST_OS),Linux)
XSH_BIN_DIR ?= $(if $(wildcard $(XSH_RELEASE_DIR)/xsh),$(XSH_RELEASE_DIR),$(HOST_TOOLS_DIR))
else
XSH_BIN_DIR ?= $(XSH_RELEASE_DIR)
endif
XSH ?= $(XSH_BIN_DIR)/xsh
XSHT ?= $(XSH_BIN_DIR)/xsht
XSH_HOST ?= $(XSH)
CARGO ?= cargo
CARGO_JOBS ?= 4

HOST_XSH_ENV = PATH="$(XSH_BIN_DIR):$$PATH" XSH_HOST="$(XSH_HOST)" XSH_ROOT="$(XSH_ROOT_ABS)" XSH_MODULE_PATH="$(CURDIR)"
LAPUTA_PROFILE_ENV = XSH_MODULE_PATH="$(CURDIR)" XSH_ROOT="$(XSH_ROOT_ABS)"

# The seed, image, and package target architecture.
ARCH ?= $(HOST_ARCH)
SEED = $(HOST_XSH_ENV) $(XSH) seed/seed.xsh --
SEED_ARGS = --arch $(ARCH) --xsh-root "$(XSH_ROOT_ABS)"
PKGDIRS ?= $(sort $(patsubst %/PKGBUILD.xsh,%,$(wildcard packages/*/PKGBUILD.xsh)))
PM_TESTS := $(sort $(wildcard tests/pm/*.xsh))
UPDATE_CHECKSUM_JOBS ?= 8
XSH_NATIVE_BIN_DIR ?= $(XSH_ROOT_ABS)/target/debug

# Docker state Laputa creates; `make clean` removes exactly these.
LAPUTA_IMAGE_REPOSITORIES := laputa-host-tools laputa-package-tools
# Legacy named volumes from before the artifact store moved under .out/.
LEGACY_LAPUTA_VOLUMES := laputa-artifacts-aarch64-v2 laputa-sources-aarch64-v2

# Rootful Docker on Linux leaves the files containers write into .out/ owned
# by root, so derived state is removed from a container there whenever the
# `xsh-test` image (which every such container build needs) exists. macOS
# Docker maps container writes to the host user.
ifeq ($(HOST_OS),Linux)
REMOVE_DERIVED = remove() { \
	    if docker image inspect $(XSH_TEST_IMAGE) >/dev/null 2>&1; then \
	        docker run --rm --pull never --network none --mount type=bind,src=$(CURDIR),dst=/laputa \
	            --workdir /laputa $(XSH_TEST_IMAGE) rm -rf "$$@"; \
	    else rm -rf "$$@"; fi; }; remove
else
REMOVE_DERIVED = rm -rf
endif

MIRROR := mirror
DEB_ARCH ?= amd64
DEB_NAME ?= laputa-mirror_0.1.0_$(DEB_ARCH).deb
DEPLOY_HOST ?= oracle
PNPM_VERSION ?= 11.0.2
PNPM_ROOT ?= target/pnpm

.PHONY: check lint test test-pm test-system test-xinit test-linux verify clean distclean fetch fetch-seed seed seed-smoke \
	need-xsh host-xsh host-mirror fetch-mirror \
	plan build publish root \
	profile-plan profile-build profile-test profile-boot profile-clean \
	test-pm-native test-pm-docker xsh-native update-checksums \
	installer-image installer-qemu-test \
	installer-qemu-manual \
	mirror mirror-build mirror-test mirror-frontend mirror-demo mirror-build-x86_64-musl mirror-deb mirror-deploy mirror-clean

# xsht-config.ini owns the module path and the excluded fixture and mirror trees.
# xsht finds only *.xsh files; XSH programs installed under other names (boot
# hooks, rootfs commands such as getent) are found by their shebang.
XSH_SHEBANG_SCRIPTS = $(shell git grep -l -e '^\#!/bin/xsh' -- ':!*.xsh' ':!tests/pm/fixtures')
check: need-xsh
	$(HOST_XSH_ENV) $(XSHT) check
	$(HOST_XSH_ENV) $(XSHT) check $(XSH_SHEBANG_SCRIPTS)

lint: need-xsh
	$(HOST_XSH_ENV) $(XSHT) lint pm.xsh pm system installer xinit

test: test-pm test-system test-xinit test-linux

test-pm: need-xsh
	$(HOST_XSH_ENV) $(XSHT) test tests/pm

# `xsht test` takes one filter per run.
test-system: need-xsh
	$(HOST_XSH_ENV) $(XSHT) test tests/system
	$(HOST_XSH_ENV) $(XSHT) test tests/integration

test-xinit: need-xsh
	$(HOST_XSH_ENV) $(XSHT) test --fail-fast xinit/tests

# The kernel recipe's Kbuild tests and linux-headers' headers_install tests.
# The kbuild tests write the stable archive-plan cache, which defaults to
# /var/cache/laputa/linux-kbuild. They get their own directory under .out/
# (which `make clean` owns), apart from the build containers' cache at
# .out/cache/linux-kbuild, which those write as root.
LINUX_KBUILD_TEST_CACHE := $(CURDIR)/.out/cache/linux-kbuild-tests
test-linux: need-xsh
	mkdir -p "$(LINUX_KBUILD_TEST_CACHE)"
	$(HOST_XSH_ENV) XSH_LINUX_KBUILD_PLAN_CACHE_DIR="$(LINUX_KBUILD_TEST_CACHE)" $(XSHT) test packages/linux/tests
	$(HOST_XSH_ENV) $(XSHT) test packages/linux-headers/tests

# The whole host proof from `make clean`: host tools, fetch, seed, the world,
# publish, root, the installer image and its QEMU proof, the qemu-dwl-foot
# proof, check, the native suites, mirror-test, and a no-op rebuild, one step
# at a time. Logs and the timing table go to .out/verify/.
verify: need-xsh
	$(HOST_XSH_ENV) $(XSH) seed/verify.xsh -- $(ARCH)

# All derived state: .out/ (seed, artifact store, cargo target, image
# contexts), target/ (profile and installer outputs), mirror build outputs,
# and Laputa's Docker images and legacy volumes. Fetched inputs in .cache/
# survive; `xsh-test` belongs to XSH and survives too.
clean: mirror-clean
	$(REMOVE_DERIVED) .out target
	@images="$$(docker image ls --quiet $(foreach repository,$(LAPUTA_IMAGE_REPOSITORIES),--filter reference=$(repository)) | sort -u)"; \
	    if [ -n "$$images" ]; then docker image rm --force $$images; fi
	docker volume rm --force $(LEGACY_LAPUTA_VOLUMES)

distclean: clean
	rm -rf .cache

# Every target that runs host XSH names this first, so a fresh Linux host
# learns to run `make host-xsh` instead of failing on a missing binary.
need-xsh:
	@for tool in "$(XSH)" "$(XSHT)"; do \
	    command -v "$$tool" >/dev/null || { \
	        echo "no host XSH at $$tool: run \`make host-xsh\` (Linux), or build $(XSH_ROOT_ABS) with cargo build --release" >&2; exit 1; }; \
	done

# Host tools for a Linux host with only git, make, and Docker: static musl
# xsh/xshi/xsht for the host architecture, built in XSH's `xsh-test` image
# (XSH_ROOT's Dockerfile.test) with plain docker, so no XSH or Rust is needed
# to start. The cargo invocation is the seed build's
# (seed/xsh_seed.xsh::xsh_seed_cargo_build_argv) for the host triple, with the
# same target dir, crate registry, flags, and features: keep them identical,
# so this build and `make seed` for the host arch share every compiled unit.
# It is networked only while the image or XSH_ROOT's crates are missing; the
# registry stamp is the one `make fetch` writes.
XSH_TEST_IMAGE := xsh-test
XSH_SEED_FEATURES := xsh/net xsh/tools xsht/native-tests
CARGO_REGISTRY := $(CURDIR)/.cache/cargo/registry
CARGO_REGISTRY_STAMP := $(CURDIR)/.cache/cargo/Cargo.lock.sha256
XSH_CARGO_TARGET := $(CURDIR)/.out/xsh-target
MIRROR_CARGO_TARGET := $(CURDIR)/.out/mirror-target
HOST_RUSTFLAGS_VAR := CARGO_TARGET_$(if $(filter x86_64,$(HOST_ARCH)),X86_64,AARCH64)_UNKNOWN_LINUX_MUSL_RUSTFLAGS
MUSL_RUSTFLAGS := -C target-feature=+crt-static -C link-arg=--defsym=__isoc23_sscanf=sscanf -C link-arg=--defsym=__isoc23_strtol=strtol
SHA256 := $(if $(filter Darwin,$(HOST_OS)),shasum -a 256,sha256sum)
HOST_DOCKER_RUN = docker run --rm --pull never --platform $(HOST_DOCKER_PLATFORM)
HOST_CARGO_FETCH = $(HOST_DOCKER_RUN) \
	--mount type=bind,src=$(CARGO_REGISTRY),dst=/root/.cargo/registry \
	--workdir /work
HOST_CARGO_BUILD = $(HOST_DOCKER_RUN) --network none \
	--mount type=bind,src=$(CARGO_REGISTRY),dst=/root/.cargo/registry \
	--workdir /work \
	--env CARGO_TARGET_DIR=/target \
	--env CARGO_NET_OFFLINE=true \
	--env CARGO_PROFILE_RELEASE_LTO=false \
	--env CARGO_PROFILE_RELEASE_INCREMENTAL=true \
	--env "$(HOST_RUSTFLAGS_VAR)=$(MUSL_RUSTFLAGS)"

host-xsh:
	@case "$(HOST_OS)/$(HOST_ARCH)" in Linux/aarch64|Linux/x86_64|Darwin/aarch64) ;; \
	    *) echo "make host-xsh: unsupported host $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1 ;; esac
	@test -f "$(XSH_ROOT_ABS)/Dockerfile.test" -a -f "$(XSH_ROOT_ABS)/Cargo.lock" || \
	    { echo "make host-xsh: XSH_ROOT=$(XSH_ROOT_ABS) is not an XSH checkout" >&2; exit 1; }
	docker image inspect $(XSH_TEST_IMAGE) >/dev/null 2>&1 || \
	    docker build --platform $(HOST_DOCKER_PLATFORM) --tag $(XSH_TEST_IMAGE) --file "$(XSH_ROOT_ABS)/Dockerfile.test" "$(XSH_ROOT_ABS)"
	mkdir -p "$(CARGO_REGISTRY)" "$(XSH_CARGO_TARGET)" "$(HOST_TOOLS_DIR)"
	@lock="$$($(SHA256) "$(XSH_ROOT_ABS)/Cargo.lock" | cut -d ' ' -f 1)"; \
	    if [ "$$(cat "$(CARGO_REGISTRY_STAMP)" 2>/dev/null)" != "$$lock" ]; then \
	        echo "fetching XSH crates for $(XSH_ROOT_ABS)/Cargo.lock"; \
	        $(HOST_CARGO_FETCH) --mount type=bind,src=$(XSH_ROOT_ABS),dst=/work,readonly \
	            $(XSH_TEST_IMAGE) cargo fetch --locked && \
	        printf '%s' "$$lock" > "$(CARGO_REGISTRY_STAMP)"; \
	    fi
	$(HOST_CARGO_BUILD) \
	    --mount type=bind,src=$(XSH_ROOT_ABS),dst=/work,readonly \
	    --mount type=bind,src=$(XSH_CARGO_TARGET),dst=/target \
	    $(XSH_TEST_IMAGE) cargo build --locked --offline --release -j $(CARGO_JOBS) --target $(HOST_TRIPLE) \
	    -p xsh -p xshi -p xsht --no-default-features --features "$(XSH_SEED_FEATURES)" --bin xsh --bin xshi --bin xsht
	@for tool in xsh xshi xsht; do \
	    cp "$(XSH_CARGO_TARGET)/$(HOST_TRIPLE)/release/$$tool" "$(HOST_TOOLS_DIR)/$$tool.tmp" && \
	    chmod 755 "$(HOST_TOOLS_DIR)/$$tool.tmp" && mv -f "$(HOST_TOOLS_DIR)/$$tool.tmp" "$(HOST_TOOLS_DIR)/$$tool" || exit 1; \
	done
	@echo "host tools $(HOST_TOOLS_DIR)"

# The mirror for a host without a Rust toolchain: the same `xsh-test` image
# and flags build a static laputa-mirror into .out/host/<host arch>/, offline
# from the crates `make fetch` stores. The toolchain file's channel is passed
# as RUSTUP_TOOLCHAIN so offline rustup uses that installed nightly instead of
# syncing the file's component list; mirror/rust-toolchain.toml must name the
# nightly XSH's Dockerfile.test installs.
MIRROR_TOOLCHAIN := $(shell sed -n 's/^channel *= *"\(.*\)"/\1/p' $(MIRROR)/rust-toolchain.toml)
host-mirror:
	mkdir -p "$(MIRROR_CARGO_TARGET)" "$(HOST_TOOLS_DIR)"
	$(HOST_CARGO_BUILD) --env RUSTUP_TOOLCHAIN=$(MIRROR_TOOLCHAIN) \
	    --mount type=bind,src=$(CURDIR)/$(MIRROR),dst=/work,readonly \
	    --mount type=bind,src=$(MIRROR_CARGO_TARGET),dst=/target \
	    $(XSH_TEST_IMAGE) cargo build --locked --offline --release -j $(CARGO_JOBS) --target $(HOST_TRIPLE) --bin laputa-mirror
	cp "$(MIRROR_CARGO_TARGET)/$(HOST_TRIPLE)/release/laputa-mirror" "$(HOST_TOOLS_DIR)/laputa-mirror.tmp"
	chmod 755 "$(HOST_TOOLS_DIR)/laputa-mirror.tmp"
	mv -f "$(HOST_TOOLS_DIR)/laputa-mirror.tmp" "$(HOST_TOOLS_DIR)/laputa-mirror"

# Offline: static musl xsh/xshi/xsht and core.tar.xz from XSH_ROOT under
# .out/seed/$(ARCH), then the package-tools image. Incremental through the
# cargo target dir in .out/xsh-target.
seed: need-xsh
	$(SEED) build $(SEED_ARGS) --jobs $(CARGO_JOBS)

# Offline proof that the seed runs in package-tools with --network none.
seed-smoke: need-xsh
	$(SEED) smoke $(SEED_ARGS)

# Package builds on the seed (seed/world.xsh). `plan` and `build` run PM in
# package-tools with --network none, the checkout and source cache read-only,
# and the artifact store at .out/artifacts/$(ARCH); the plan lands in
# .out/world/$(ARCH)/plan.json. Select PKGS="a b" (their closures), STOP=pre-cmake
# (every package whose build closure needs neither cmake nor linux), or
# neither (every package). The store is the build cache: an unchanged rebuild
# reuses every artifact.
#
# Containers have no network, so only the host talks to the loopback mirror:
# `publish` builds the same selection, then uploads that plan's artifacts
# from the host (never a stale plan), and `root`
# imports PKGS from the mirror into a fresh store on the host, then composes,
# inspects, and runs that root in an offline container
# (.out/world/$(ARCH)/root/). Both need `make mirror` running.
WORLD = $(HOST_XSH_ENV) $(XSH) seed/world_cli.xsh --
PKGS ?=
STOP ?=
JOBS ?= 4
MIRROR_URL ?= http://127.0.0.1:$(MIRROR_PORT)
WORLD_SELECTION = $(foreach package,$(PKGS),--package $(package)) $(if $(STOP),--stop $(STOP))

plan: need-xsh
	$(WORLD) plan --arch $(ARCH) $(WORLD_SELECTION)

build: need-xsh
	$(WORLD) build --arch $(ARCH) --jobs $(JOBS) $(WORLD_SELECTION)

publish: need-xsh
	$(WORLD) publish --arch $(ARCH) --jobs $(JOBS) --repo $(MIRROR_URL) $(WORLD_SELECTION)

root: need-xsh
	$(REMOVE_DERIVED) .out/world/$(ARCH)/root
	$(WORLD) root --arch $(ARCH) --jobs $(JOBS) --repo $(MIRROR_URL) $(WORLD_SELECTION)

# The only networked step: every pinned upstream source the recipes use on
# ARCH (the LLVM seed included), sha256-verified into the content-addressed
# cache at $(SOURCE_CACHE)/sha256/<hash>, which `make mirror` serves, plus the
# seed inputs. Builds read that cache or LAPUTA_MIRROR and never contact
# upstream hosts.
SOURCE_CACHE ?= $(CURDIR)/.cache/sources
fetch: fetch-seed $(FETCH_HOST_MIRROR)
	$(HOST_XSH_ENV) LAPUTA_SOURCE_CACHE="$(SOURCE_CACHE)" $(XSH) pm.xsh -- sources fetch --repo . --all --target $(ARCH)-linux-musl

# The mirror's crates for `make host-mirror`, in the image `fetch-seed` provides.
fetch-mirror: fetch-seed
	mkdir -p "$(CARGO_REGISTRY)"
	$(HOST_CARGO_FETCH) --mount type=bind,src=$(CURDIR)/$(MIRROR),dst=/work,readonly $(XSH_TEST_IMAGE) cargo fetch --locked

# The networked seed inputs: XSH's crates for XSH_ROOT's Cargo.lock in
# .cache/cargo, the xsh-test image (XSH's Dockerfile.test), and the
# host-tools base saved under .cache/images/.
fetch-seed: need-xsh
	$(SEED) fetch $(SEED_ARGS)

# The typed profile CLI is the sole core-system orchestration surface.
profile-plan:
	$(LAPUTA_PROFILE_ENV) $(XSH_HOST) laputa.xsh -- plan qemu-dwl-foot

profile-build:
	$(LAPUTA_PROFILE_ENV) $(XSH_HOST) laputa.xsh -- build qemu-dwl-foot

profile-test:
	$(LAPUTA_PROFILE_ENV) $(XSH_HOST) laputa.xsh -- test qemu-dwl-foot

profile-boot:
	$(LAPUTA_PROFILE_ENV) $(XSH_HOST) laputa.xsh -- boot qemu-dwl-foot

profile-clean:
	$(LAPUTA_PROFILE_ENV) $(XSH_HOST) laputa.xsh -- clean qemu-dwl-foot

# Host-native PM suite on Linux against the checked-out debug XSH.
test-pm-native: xsh-native
	@mkdir -p target/coverage/pm-native
	@set -eu; for suite in $(PM_TESTS); do \
	    name=$${suite##*/}; name=$${name%.xsh}; \
	    PATH="$(XSH_NATIVE_BIN_DIR):$$PATH" \
	    XSH_HOST="$(XSH_NATIVE_BIN_DIR)/xsh" \
	    XSH_MODULE_PATH="$(CURDIR)" \
	    "$(XSH_NATIVE_BIN_DIR)/xsht" test --cov --cov-json "target/coverage/pm-native/$$name.json" "$$suite"; \
	done

xsh-native:
	$(CARGO) build -j $(CARGO_JOBS) --manifest-path "$(XSH_ROOT_ABS)/Cargo.toml" -p xsh -p xshi -p xsht --bin xsh --bin xshi --bin xsht

# The full PM suite inside package-tools with the seed mounted, offline.
test-pm-docker: need-xsh
	$(SEED) smoke $(SEED_ARGS) tests/pm

update-checksums: need-xsh
	@printf '%s\n' $(PKGDIRS) | xargs -n 1 -P $(UPDATE_CHECKSUM_JOBS) sh -c 'pkg="$$1"; name="$${pkg#packages/}"; XSH_MODULE_PATH="$(CURDIR)" $(XSH) pm.xsh -- repo update-checksums --repo . "$$name"' sh

# Installer workflows are not part of the qemu-dwl-foot profile lifecycle.
# Both import ARCH's installer roots from the local mirror, so they need
# `make mirror` running and `make publish` done; the QEMU proof builds its own
# smoke-mode image, then installs and boots it (KVM on x86_64).
installer-image: need-xsh
	$(HOST_XSH_ENV) LAPUTA_REPO_URL="$(MIRROR_URL)" $(XSH_HOST) build-installer-common.xsh -- $(ARCH)

installer-qemu-test: need-xsh
	$(HOST_XSH_ENV) LAPUTA_REPO_URL="$(MIRROR_URL)" LAPUTA_INSTALLER_ARCH=$(ARCH) $(XSH_HOST) installer-qemu-test.xsh

installer-qemu-manual:
	$(XSH_HOST) installer-qemu-manual.xsh

# The mirror is a host tool; cargo must run inside mirror/ so its
# rust-toolchain.toml applies.
mirror-build:
	cd $(MIRROR) && $(CARGO) build -j $(CARGO_JOBS) --locked

# Local-only mirror on http://127.0.0.1:$(MIRROR_PORT): packages under
# .out/mirror (derived), the fetched source cache served read-only at
# /sources/sha256/<hash>. No auth; loopback only.
MIRROR_PORT ?= 3000
MIRROR_DATA ?= $(CURDIR)/.out/mirror
mirror: $(MIRROR_SERVER_DEPS)
	mkdir -p "$(MIRROR_DATA)" "$(SOURCE_CACHE)/sha256"
	$(MIRROR_SERVER) --local "$(MIRROR_DATA)" --listen "127.0.0.1:$(MIRROR_PORT)" --sources "$(SOURCE_CACHE)"

# Linux hosts test the mirror in `xsh-test` the way `host-mirror` builds it,
# offline from the crates `make fetch` stores, so no host Rust is needed.
ifeq ($(HOST_OS),Linux)
mirror-test:
	mkdir -p "$(MIRROR_CARGO_TARGET)"
	$(HOST_CARGO_BUILD) --env RUSTUP_TOOLCHAIN=$(MIRROR_TOOLCHAIN) \
	    --mount type=bind,src=$(CURDIR)/$(MIRROR),dst=/work,readonly \
	    --mount type=bind,src=$(MIRROR_CARGO_TARGET),dst=/target \
	    $(XSH_TEST_IMAGE) cargo test --locked --offline -j $(CARGO_JOBS) --target $(HOST_TRIPLE)
else
mirror-test:
	cd $(MIRROR) && $(CARGO) test -j $(CARGO_JOBS) --locked
endif

mirror-build-x86_64-musl:
	mkdir -p $(MIRROR)/target/docker-output
	cd $(MIRROR) && docker buildx build \
	  --platform linux/amd64 \
	  --output type=local,dest=target/docker-output \
	  .

mirror-frontend:
	cd $(MIRROR) && deno install --global --allow-all --unsafe-proto --root "$(PNPM_ROOT)" --name pnpm npm:pnpm@$(PNPM_VERSION)
	cd $(MIRROR) && "$(PNPM_ROOT)/bin/pnpm" install --frozen-lockfile
	cd $(MIRROR) && "$(PNPM_ROOT)/bin/pnpm" run build

# Interactive passkey walkthrough on http://localhost:3000; see mirror/examples/demo.rs.
mirror-demo: mirror-frontend
	cd $(MIRROR) && $(CARGO) run -j $(CARGO_JOBS) --example demo

mirror-deb: mirror-build-x86_64-musl mirror-frontend
	cd $(MIRROR) && rm -rf target/deb-root
	cd $(MIRROR) && install -d target/deb-root/DEBIAN target/deb-root/usr/bin target/deb-root/lib/systemd/system target/deb-root/etc/laputa-mirror target/deb-root/usr/share/laputa-mirror
	cd $(MIRROR) && install -m 755 target/docker-output/laputa-mirror target/deb-root/usr/bin/laputa-mirror
	cd $(MIRROR) && install -m 644 laputa-mirror.service target/deb-root/lib/systemd/system/laputa-mirror.service
	cd $(MIRROR) && install -m 600 laputa-mirror.env.example target/deb-root/etc/laputa-mirror/env.example
	cd $(MIRROR) && cp -R static target/deb-root/usr/share/laputa-mirror/
	cd $(MIRROR) && printf '%s\n' \
	  'Package: laputa-mirror' \
	  'Version: 0.1.0' \
	  "Architecture: $(DEB_ARCH)" \
	  'Maintainer: Laputa Systems' \
	  'Description: Laputa package mirror' \
	  > target/deb-root/DEBIAN/control
	cd $(MIRROR) && printf '%s\n' \
	  '#!/bin/sh' \
	  'set -e' \
	  'if ! getent passwd laputa-mirror >/dev/null; then' \
	  '  useradd --system --home /var/lib/laputa-mirror --shell /usr/sbin/nologin laputa-mirror' \
	  'fi' \
	  'install -d -o laputa-mirror -g laputa-mirror /var/lib/laputa-mirror' \
	  'if [ ! -f /etc/laputa-mirror/env ]; then' \
	  '  install -m 600 -o root -g root /etc/laputa-mirror/env.example /etc/laputa-mirror/env' \
	  'fi' \
	  'if command -v systemctl >/dev/null; then' \
	  '  systemctl daemon-reload || true' \
	  'fi' \
	  > target/deb-root/DEBIAN/postinst
	cd $(MIRROR) && chmod 755 target/deb-root/DEBIAN/postinst
	cd $(MIRROR) && dpkg-deb --root-owner-group --build target/deb-root $(DEB_NAME)

mirror-deploy: mirror-deb
	scp "$(MIRROR)/$(DEB_NAME)" "$(DEPLOY_HOST):/tmp/$(DEB_NAME)"
	ssh "$(DEPLOY_HOST)" "set -eu; sudo dpkg -i /tmp/$(DEB_NAME); sudo systemctl daemon-reload; sudo systemctl restart laputa-mirror; sudo systemctl enable --now laputa-mirror; sudo systemctl status --no-pager laputa-mirror"

mirror-clean:
	rm -rf $(MIRROR)/node_modules $(MIRROR)/target/pnpm $(MIRROR)/target/deb-root $(MIRROR)/target/docker-output
	rm -f $(MIRROR)/static/js/auth.js $(MIRROR)/static/js/settings.js
