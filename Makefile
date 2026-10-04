# Single entry point for the Laputa monorepo.
#
# XSH is co-developed in its own checkout at XSH_ROOT. Host tools default to
# its release binaries; PM loads PKGBUILD modules and spawns XSH runners at
# runtime, and those resolve `pm.*` imports only through XSH_MODULE_PATH,
# which xsht-config.ini cannot provide.

XSH_ROOT ?= ../xsh
XSH_ROOT_ABS := $(abspath $(XSH_ROOT))
XSH_BIN_DIR ?= $(XSH_ROOT_ABS)/target/release
XSH ?= $(XSH_BIN_DIR)/xsh
XSHT ?= $(XSH_BIN_DIR)/xsht
XSH_HOST ?= $(XSH)
CARGO ?= cargo
CARGO_JOBS ?= 4

HOST_XSH_ENV = PATH="$(XSH_BIN_DIR):$$PATH" XSH_HOST="$(XSH_HOST)" XSH_ROOT="$(XSH_ROOT_ABS)" XSH_MODULE_PATH="$(CURDIR)"
LAPUTA_PROFILE_ENV = XSH_MODULE_PATH="$(CURDIR)" XSH_ROOT="$(XSH_ROOT_ABS)"

# The seed and image architecture. The macOS bootstrap builds aarch64; a Linux
# amd64 host passes ARCH=x86_64.
ARCH ?= aarch64
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

MIRROR := mirror
DEB_ARCH ?= amd64
DEB_NAME ?= laputa-mirror_0.1.0_$(DEB_ARCH).deb
DEPLOY_HOST ?= oracle
PNPM_VERSION ?= 11.0.2
PNPM_ROOT ?= target/pnpm

.PHONY: check lint test test-pm test-system test-xinit clean distclean fetch fetch-seed seed seed-smoke \
	plan build publish root \
	profile-plan profile-build profile-test profile-boot profile-clean \
	test-pm-native test-pm-docker xsh-native update-checksums \
	installer-image installer-image-aarch64 installer-qemu-test installer-qemu-test-aarch64 \
	installer-qemu-manual \
	mirror mirror-build mirror-test mirror-frontend mirror-demo mirror-build-x86_64-musl mirror-deb mirror-deploy mirror-clean

# xsht-config.ini owns the module path and the excluded fixture and mirror trees.
check:
	$(HOST_XSH_ENV) $(XSHT) check

lint:
	$(HOST_XSH_ENV) $(XSHT) lint pm.xsh pm system installer xinit

test: test-pm test-system test-xinit

test-pm:
	$(HOST_XSH_ENV) $(XSHT) test tests/pm

# `xsht test` takes one filter per run.
test-system:
	$(HOST_XSH_ENV) $(XSHT) test tests/system
	$(HOST_XSH_ENV) $(XSHT) test tests/integration

test-xinit:
	$(HOST_XSH_ENV) $(XSHT) test --fail-fast xinit/tests

# All derived state: .out/ (seed, artifact store, cargo target, image
# contexts), target/ (profile and installer outputs), mirror build outputs,
# and Laputa's Docker images and legacy volumes. Fetched inputs in .cache/
# survive; `xsh-test` belongs to XSH and survives too.
clean: mirror-clean
	rm -rf .out target
	@images="$$(docker image ls --quiet $(foreach repository,$(LAPUTA_IMAGE_REPOSITORIES),--filter reference=$(repository)) | sort -u)"; \
	    if [ -n "$$images" ]; then docker image rm --force $$images; fi
	docker volume rm --force $(LEGACY_LAPUTA_VOLUMES)

distclean: clean
	rm -rf .cache

# Offline: static musl xsh/xshi/xsht and core.tar.xz from XSH_ROOT under
# .out/seed/$(ARCH), then the package-tools image. Incremental through the
# cargo target dir in .out/xsh-target.
seed:
	$(SEED) build $(SEED_ARGS) --jobs $(CARGO_JOBS)

# Offline proof that the seed runs in package-tools with --network none.
seed-smoke:
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

plan:
	$(WORLD) plan --arch $(ARCH) $(WORLD_SELECTION)

build:
	$(WORLD) build --arch $(ARCH) --jobs $(JOBS) $(WORLD_SELECTION)

publish:
	$(WORLD) publish --arch $(ARCH) --jobs $(JOBS) --repo $(MIRROR_URL) $(WORLD_SELECTION)

root:
	rm -rf .out/world/$(ARCH)/root
	$(WORLD) root --arch $(ARCH) --jobs $(JOBS) --repo $(MIRROR_URL) $(WORLD_SELECTION)

# The only networked step: every pinned upstream source the recipes use on
# ARCH (the LLVM seed included), sha256-verified into the content-addressed
# cache at $(SOURCE_CACHE)/sha256/<hash>, which `make mirror` serves, plus the
# seed inputs. Builds read that cache or LAPUTA_MIRROR and never contact
# upstream hosts.
SOURCE_CACHE ?= $(CURDIR)/.cache/sources
fetch: fetch-seed
	$(HOST_XSH_ENV) LAPUTA_SOURCE_CACHE="$(SOURCE_CACHE)" $(XSH) pm.xsh -- sources fetch --repo . --all --target $(ARCH)-linux-musl

# The networked seed inputs: XSH's crates for XSH_ROOT's Cargo.lock in
# .cache/cargo, the xsh-test image (XSH's Dockerfile.test), and the
# host-tools base saved under .cache/images/.
fetch-seed:
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
test-pm-docker:
	$(SEED) smoke $(SEED_ARGS) tests/pm

update-checksums:
	@printf '%s\n' $(PKGDIRS) | xargs -n 1 -P $(UPDATE_CHECKSUM_JOBS) sh -c 'pkg="$$1"; name="$${pkg#packages/}"; XSH_MODULE_PATH="$(CURDIR)" $(XSH) pm.xsh -- repo update-checksums --repo . "$$name"' sh

# Installer workflows are not part of the qemu-dwl-foot profile lifecycle.
installer-image: installer-image-aarch64

installer-image-aarch64:
	$(XSH_HOST) build-installer-aarch64.xsh

installer-qemu-test: installer-qemu-test-aarch64

installer-qemu-test-aarch64:
	$(XSH_HOST) installer-qemu-test.xsh

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
mirror:
	mkdir -p "$(MIRROR_DATA)" "$(SOURCE_CACHE)/sha256"
	cd $(MIRROR) && $(CARGO) run -j $(CARGO_JOBS) --locked --bin laputa-mirror -- --local "$(MIRROR_DATA)" --listen "127.0.0.1:$(MIRROR_PORT)" --sources "$(SOURCE_CACHE)"

mirror-test:
	cd $(MIRROR) && $(CARGO) test -j $(CARGO_JOBS) --locked

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
	cd $(MIRROR) && install -m 755 target/docker-output/laputa-mirror-publish target/deb-root/usr/bin/laputa-mirror-publish
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
