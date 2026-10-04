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
LAPUTA_LOCAL_XSH_BIN ?=
CARGO ?= cargo
CARGO_JOBS ?= 4

HOST_XSH_ENV = PATH="$(XSH_BIN_DIR):$$PATH" XSH_HOST="$(XSH_HOST)" XSH_ROOT="$(XSH_ROOT_ABS)" XSH_MODULE_PATH="$(CURDIR)"
LAPUTA_PROFILE_ENV = XSH_MODULE_PATH="$(CURDIR)" XSH_ROOT="$(XSH_ROOT_ABS)" LAPUTA_LOCAL_XSH_BIN="$(LAPUTA_LOCAL_XSH_BIN)"

LAPUTA_DOCKER_PLATFORM ?= linux/arm64
XSH_TEST_IMAGE ?= laputa-pm-test
XSH_BUILD_IMAGE ?= xsh-test
XSH_RELEASE ?= release-d09c6c3305ab8c650043bd8d32e03f2db6509e97
PKGDIRS ?= $(sort $(patsubst %/PKGBUILD.xsh,%,$(wildcard packages/*/PKGBUILD.xsh)))
PM_TESTS := $(sort $(wildcard tests/pm/*.xsh))
UPDATE_CHECKSUM_JOBS ?= 8

ifeq ($(LAPUTA_DOCKER_PLATFORM),linux/amd64)
XSH_LOCAL_TRIPLE ?= x86_64-unknown-linux-musl
XSH_RELEASE_ARCH ?= x86_64
XSH_RELEASE_XSH_SHA256 ?= 03e190c8ee15020b04b27e2066a7e53665452c9dce821bd0af80378ef664c746
XSH_RELEASE_XSHI_SHA256 ?= 897b22cae065625179f8b2cb18c48828464eb1cd135f32da0e9358b237f3e195
XSH_RELEASE_XSHT_SHA256 ?= 83ea617d6fc1a9f9e7908b292d51d8b263df15904d67d17b7c7f04d825a98a20
XSH_LOCAL_RUSTFLAGS_VAR := CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS
else
XSH_LOCAL_TRIPLE ?= aarch64-unknown-linux-musl
XSH_RELEASE_ARCH ?= aarch64
XSH_RELEASE_XSH_SHA256 ?= bc9117b8ac70c726002835e7ab1eaff0d45ede7b067bc85ddba7971eb8b8ffbb
XSH_RELEASE_XSHI_SHA256 ?= 5cf2f028fd0f0e6cbae213d7037e28e1aa92ca74768c5fce5e300d9725014bb6
XSH_RELEASE_XSHT_SHA256 ?= 86c2d1ac329702c0def779adb47640f84cdda9466630e2c98681750fc037a2e2
XSH_LOCAL_RUSTFLAGS_VAR := CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS
endif

XSH_LOCAL_RUSTFLAGS ?= -C target-feature=+crt-static -C link-arg=--defsym=__isoc23_sscanf=sscanf -C link-arg=--defsym=__isoc23_strtol=strtol
XSH_LOCAL_BIN_DIR ?= $(XSH_ROOT_ABS)/target/$(XSH_LOCAL_TRIPLE)/debug
XSH_NATIVE_BIN_DIR ?= $(XSH_ROOT_ABS)/target/debug

MIRROR := mirror
DEB_ARCH ?= amd64
DEB_NAME ?= laputa-mirror_0.1.0_$(DEB_ARCH).deb
DEPLOY_HOST ?= oracle
PNPM_VERSION ?= 11.0.2
PNPM_ROOT ?= target/pnpm

.PHONY: check lint test test-pm test-system test-xinit clean \
	profile-plan profile-build profile-test profile-boot profile-clean \
	test-pm-native test-pm-docker test-pm-local-linux xsh-native xsh-local-bins xsh-builder-image update-checksums \
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

clean: mirror-clean
	rm -rf .out target

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
	    XSH_PM_BUILD_CHROOT=0 \
	    "$(XSH_NATIVE_BIN_DIR)/xsht" test --cov --cov-json "target/coverage/pm-native/$$name.json" "$$suite"; \
	done

xsh-native:
	$(CARGO) build -j $(CARGO_JOBS) --manifest-path "$(XSH_ROOT_ABS)/Cargo.toml" -p xsh -p xshi -p xsht --bin xsh --bin xshi --bin xsht

# PM suite in a scratch image built from pinned published XSH release binaries.
test-pm-docker:
	docker build \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    --build-arg XSH_RELEASE=$(XSH_RELEASE) \
	    --build-arg XSH_RELEASE_ARCH=$(XSH_RELEASE_ARCH) \
	    --build-arg XSH_RELEASE_XSH_SHA256=$(XSH_RELEASE_XSH_SHA256) \
	    --build-arg XSH_RELEASE_XSHI_SHA256=$(XSH_RELEASE_XSHI_SHA256) \
	    --build-arg XSH_RELEASE_XSHT_SHA256=$(XSH_RELEASE_XSHT_SHA256) \
	    -t $(XSH_TEST_IMAGE) \
	    -f Dockerfile.pm-test \
	    .
	@mkdir -p target/coverage/pm
	@set -eu; for suite in $(PM_TESTS); do \
	    name=$${suite##*/}; name=$${name%.xsh}; \
	    docker run --rm \
	        --platform $(LAPUTA_DOCKER_PLATFORM) \
	        -v "$(CURDIR)":/src/laputa \
	        $(XSH_TEST_IMAGE) \
	        xsht test --cov --cov-json "target/coverage/pm/$$name.json" "$$suite"; \
	done

xsh-local-bins: xsh-builder-image
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e $(XSH_LOCAL_RUSTFLAGS_VAR)='$(XSH_LOCAL_RUSTFLAGS)' \
	    -v "$(XSH_ROOT_ABS)":/work \
	    -v "$(XSH_ROOT_ABS)/target/$(XSH_LOCAL_TRIPLE)":/work/target/$(XSH_LOCAL_TRIPLE) \
	    -w /work \
	    $(XSH_BUILD_IMAGE) \
	    sh -c 'cargo build -j $(CARGO_JOBS) --target $(XSH_LOCAL_TRIPLE) -p xsh -p xshi -p xsht --no-default-features --features "xsh/native-tests xsh/net xsh/tools xsht/native-tests" --bin xsh --bin xshi --bin xsht'

# PM suite against checked-out Linux debug XSH binaries in XSH's pinned test image.
test-pm-local-linux: xsh-local-bins
	@mkdir -p target/coverage/pm-local-linux
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e XSH_HOST=/work/target/$(XSH_LOCAL_TRIPLE)/debug/xsh \
	    -e XSH_CORE_ROOT=/work/core \
	    -e XSH_MODULE_PATH=/src/laputa \
	    -e XSH_PM_BUILD_CHROOT=0 \
	    -v "$(XSH_ROOT_ABS)":/work:ro \
	    -v "$(CURDIR)":/src/laputa \
	    -w /src/laputa \
	    $(XSH_BUILD_IMAGE) \
	    sh -c 'set -eu; export PATH="/work/target/$(XSH_LOCAL_TRIPLE)/debug:$$PATH"; for suite in $(PM_TESTS); do name=$${suite##*/}; name=$${name%.xsh}; xsht test --jobs 1 --cov --cov-json "target/coverage/pm-local-linux/$$name.json" "$$suite"; done'

xsh-builder-image:
	docker image inspect $(XSH_BUILD_IMAGE) >/dev/null 2>&1 || \
	    docker build --platform $(LAPUTA_DOCKER_PLATFORM) -t $(XSH_BUILD_IMAGE) -f "$(XSH_ROOT_ABS)/Dockerfile.test" "$(XSH_ROOT_ABS)"

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
SOURCE_CACHE ?= $(CURDIR)/.cache/sources
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
