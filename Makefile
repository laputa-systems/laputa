.PHONY: boot boot-userspace-e2e boot-tailscale-test proof-kernel ensure-proof-kernel build-essential-native packages-builder ensure-build-essential-native ensure-world-xsh ensure-world-docker-volumes world-build world-build-aarch64 world-build-amd64 world-smoke-amd64 amd64-package-test linux-amd64-config linux-amd64-prepare-proof linux-amd64-discover-proof linux-amd64-plan-proof linux-amd64-compile-proof linux-amd64-link-proof linux-amd64-package-proof linux-amd64-object linux-amd64-sources linux-amd64-cache linux-amd64-kconfig-proof package-test package-deps-test linux-plan-only linux-kbuild-oracle package-publish package-publish-userspace-arm64 pkgconf-test cmake-test samurai-test \
        dropbear-test tmux-test linux-pam-test sudo-rs-test iptables-test tailscale-test less-test dwl-foot-minimal-test ensure-dwl-foot-minimal-proof dwl-foot-minimal-qemu-debug waterfox-test ensure-waterfox-proof waterfox-qemu-test proof-rootfs \
        scratch-build-env installer-image installer-image-aarch64 installer-image-amd64 installer-image-x86_64 installer-qemu-test installer-qemu-test-aarch64 installer-qemu-test-amd64 installer-qemu-test-x86_64 installer-qemu-manual ensure-host-xsh ensure-host-xsh-release ensure-package-docker-volumes _world-build-amd64

LAPUTA_DOCKER_PLATFORM ?= linux/arm64
LAPUTA_PACKAGE_ARCH ?= aarch64
DOCKER ?= docker
LAPUTA_LINUX_VERSION ?= 7.0.5
LAPUTA_LINUX_REL ?= 30
LAPUTA_LINUX_ID := linux-$(LAPUTA_LINUX_VERSION)-$(LAPUTA_LINUX_REL)
LAPUTA_LINUX_PROOF_ROOT ?= $(CURDIR)/.xsh-linux-proof
LAPUTA_LINUX_PACKAGE := $(LAPUTA_LINUX_PROOF_ROOT)/packages/$(LAPUTA_PACKAGE_ARCH)/linux/$(LAPUTA_LINUX_ID).tar.gz
ifeq ($(LAPUTA_PACKAGE_ARCH),x86_64)
LAPUTA_LINUX_KERNEL_IMAGE ?= $(LAPUTA_LINUX_PROOF_ROOT)/.work/$(LAPUTA_LINUX_ID)/src/arch/x86/boot/bzImage
else
LAPUTA_LINUX_KERNEL_IMAGE ?= $(LAPUTA_LINUX_PROOF_ROOT)/.work/$(LAPUTA_LINUX_ID)/src/arch/arm64/boot/Image
endif
LAPUTA_LINUX_INPUTS = \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/PKGBUILD.xsh \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/kbuild.xsh \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/config/aarch64/base-aarch64.fragment \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/config/x86_64/base-x86_64.fragment \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/sysreg-defs.h \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/timeconst.h \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/bounds.h \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/asm-offsets.h \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/rq-offsets.h \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/sha256-core.S \
	$(LAPUTA_PACKAGES_ROOT)/repo/linux/files/generated/sha512-core.S \
	$(LAPUTA_PACKAGES_ROOT)/pm.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/build.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/buildroot.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/cli.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/extensions.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/install.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/local.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/remote.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/repo.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/sources.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/types.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/util.xsh \
	$(LAPUTA_PACKAGES_ROOT)/pm/world.xsh
XSH_SOURCE_ROOT ?= $(abspath $(CURDIR)/../../laputa-systems/xsh)
XSH_HOST ?= $(XSH_SOURCE_ROOT)/target/debug/xsh
CARGO ?= $(HOME)/.cargo/bin/cargo
XSH_RELEASE ?= release-d09c6c3305ab8c650043bd8d32e03f2db6509e97
XSH_CORE_SHA256 ?= 7040377b294b165fde676f6b808d32ee5d5dc0f2cc84dd6d1350974d22989c95
LAPUTA_PACKAGES_ROOT ?= $(shell if [ -d "$$HOME/d/laputa-systems/packages" ]; then printf '%s' "$$HOME/d/laputa-systems/packages"; else printf '%s' "$(abspath $(CURDIR)/../packages)"; fi)

ifeq ($(LAPUTA_PACKAGE_ARCH),aarch64)
else ifeq ($(LAPUTA_PACKAGE_ARCH),x86_64)
else
$(error unsupported LAPUTA_PACKAGE_ARCH: $(LAPUTA_PACKAGE_ARCH))
endif
ifeq ($(LAPUTA_PACKAGE_ARCH),aarch64)
XSH_RELEASE_XSH_SHA256 ?= bc9117b8ac70c726002835e7ab1eaff0d45ede7b067bc85ddba7971eb8b8ffbb
XSH_RELEASE_XSHI_SHA256 ?= 5cf2f028fd0f0e6cbae213d7037e28e1aa92ca74768c5fce5e300d9725014bb6
XSH_RELEASE_XSHT_SHA256 ?= 86c2d1ac329702c0def779adb47640f84cdda9466630e2c98681750fc037a2e2
else
XSH_RELEASE_XSH_SHA256 ?= 03e190c8ee15020b04b27e2066a7e53665452c9dce821bd0af80378ef664c746
XSH_RELEASE_XSHI_SHA256 ?= 897b22cae065625179f8b2cb18c48828464eb1cd135f32da0e9358b237f3e195
XSH_RELEASE_XSHT_SHA256 ?= 83ea617d6fc1a9f9e7908b292d51d8b263df15904d67d17b7c7f04d825a98a20
endif
XSH_HOST_RELEASE_BIN_DIR ?= $(XSH_SOURCE_ROOT)/target/host-xsh-release
XSH_RELEASE_HELPER_IMAGE ?= alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d
DOCKER_VOLUME_PREFIX ?= laputa
XSH_WORLD_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-xsh-world-$(LAPUTA_PACKAGE_ARCH)
XSH_CORE_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-xsh-core-$(LAPUTA_PACKAGE_ARCH)
LAPUTA_PACKAGES_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-packages-$(LAPUTA_PACKAGE_ARCH)
PACKAGE_TEST_CACHE_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-package-test-cache-$(LAPUTA_PACKAGE_ARCH)
PACKAGE_TEST_WORK_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-package-test-work-$(LAPUTA_PACKAGE_ARCH)
PACKAGE_TEST_SET_ROOT_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-package-test-set-root-$(LAPUTA_PACKAGE_ARCH)
PACKAGE_TEST_SET_BUILD_ROOT_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-package-test-set-build-root-$(LAPUTA_PACKAGE_ARCH)
PACKAGE_TEST_SOURCE_MIRROR_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-package-test-source-mirrors-$(LAPUTA_PACKAGE_ARCH)
WORLD_CACHE_VOLUME ?= $(DOCKER_VOLUME_PREFIX)-world-cache-$(LAPUTA_PACKAGE_ARCH)
DOCKER_SYNC_VOLUME ?= $(CURDIR)/tools/sync-docker-volume.sh

# macOS cannot run native Linux package proofs (they mount devpts, which
# /sbin/mount rejects). On darwin, default the dev-boot targets to a cross build
# (aarch64 target, x86_64 build arch) so PM uses the non-native proof path,
# matching boot-userspace-e2e. Linux hosts keep their native behavior. All three
# remain overridable from the environment.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
BOOT_ARCH_ENV = LAPUTA_PACKAGE_ARCH=$${LAPUTA_PACKAGE_ARCH:-aarch64} XSH_PM_BUILD_ARCH=$${XSH_PM_BUILD_ARCH:-x86_64} XSH_PM_TARGET_ARCH=$${XSH_PM_TARGET_ARCH:-aarch64}
else
BOOT_ARCH_ENV =
endif

ensure-host-xsh:
	@if [ -x "$(XSH_HOST)" ] || command -v "$(XSH_HOST)" >/dev/null 2>&1; then \
	    exit 0; \
	fi; \
	test -f "$(XSH_SOURCE_ROOT)/Cargo.toml"; \
	$(CARGO) build --manifest-path "$(XSH_SOURCE_ROOT)/Cargo.toml" --bin xsh

proof-kernel: $(LAPUTA_LINUX_PACKAGE)

ensure-proof-kernel:
	@test -f $(LAPUTA_LINUX_PACKAGE) || $(MAKE) proof-kernel

$(LAPUTA_LINUX_PACKAGE): $(LAPUTA_LINUX_INPUTS)
	$(MAKE) build-essential-native
	mkdir -p $(dir $(LAPUTA_LINUX_PACKAGE))
	set -e; tmp_container=$$($(DOCKER) create --platform $(LAPUTA_DOCKER_PLATFORM) $(PACKAGE_TOOLS_IMAGE)); \
	    $(DOCKER) cp $$tmp_container:/src/target/repo/packages/$(LAPUTA_PACKAGE_ARCH)/linux/$(LAPUTA_LINUX_ID).tar.gz $(LAPUTA_LINUX_PACKAGE); \
	    $(DOCKER) rm $$tmp_container >/dev/null
	mkdir -p $(dir $(LAPUTA_LINUX_KERNEL_IMAGE))
	tar -xOf $(LAPUTA_LINUX_PACKAGE) ./boot/vmlinuz > $(LAPUTA_LINUX_KERNEL_IMAGE)
	test -f $(LAPUTA_LINUX_PACKAGE)

ensure-host-xsh-release:
	set -e; mkdir -p "$(XSH_HOST_RELEASE_BIN_DIR)"; \
	for command_name in xsh xshi xsht; do \
	    case "$$command_name" in \
	        xsh) sha="$(XSH_RELEASE_XSH_SHA256)" ;; \
	        xshi) sha="$(XSH_RELEASE_XSHI_SHA256)" ;; \
	        xsht) sha="$(XSH_RELEASE_XSHT_SHA256)" ;; \
	    esac; \
	    dest="$(XSH_HOST_RELEASE_BIN_DIR)/$$command_name"; \
	    curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/laputa-systems/xsh/releases/download/$(XSH_RELEASE)/$$command_name-$(XSH_RELEASE)-$(LAPUTA_PACKAGE_ARCH)-linux-musl" -o "$$dest"; \
	    echo "$$sha  $$dest" | sha256sum -c -; \
	    chmod 0755 "$$dest"; \
	done

boot: ensure-host-xsh
	set -e; kernel_source="$${XSH_BOOT_KERNEL:-}"; \
	if [ -z "$$kernel_source" ] && [ -f "$(LAPUTA_INSTALLER_LOCAL_KERNEL)" ]; then \
	    kernel_source="$(LAPUTA_INSTALLER_LOCAL_KERNEL)"; \
	fi; \
	if [ -n "$$kernel_source" ]; then export XSH_BOOT_KERNEL="$$kernel_source"; fi; \
	XSH_BOOT_QEMU_DISPLAY=$${XSH_BOOT_QEMU_DISPLAY:-cocoa,zoom-to-fit=on,show-cursor=on} \
	XSH_SOURCE_ROOT="$${XSH_SOURCE_ROOT:-$(XSH_SOURCE_ROOT)}" \
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	$(BOOT_ARCH_ENV) \
	"$${XSH_HOST:-$(XSH_HOST)}" boot.xsh

boot-userspace-e2e: ensure-host-xsh
	set -e; kernel_source="$${XSH_BOOT_KERNEL:-}"; \
	if [ -z "$$kernel_source" ] && [ -f "$(LAPUTA_INSTALLER_LOCAL_KERNEL)" ]; then \
	    kernel_source="$(LAPUTA_INSTALLER_LOCAL_KERNEL)"; \
	fi; \
	if [ -n "$$kernel_source" ]; then export XSH_BOOT_KERNEL="$$kernel_source"; fi; \
	LAPUTA_PACKAGE_ARCH=aarch64 \
	XSH_PM_BUILD_ARCH=$${XSH_PM_BUILD_ARCH:-x86_64} \
	XSH_PM_TARGET_ARCH=aarch64 \
	XSH_BOOT_USERSPACE_E2E=1 \
	XSH_BOOT_ATTACH=0 \
	XSH_BOOT_CONSOLE_TIMEOUT=$${XSH_BOOT_CONSOLE_TIMEOUT:-90} \
	XSH_BOOT_QEMU_DISPLAY=$${XSH_BOOT_QEMU_DISPLAY:-none} \
	XSH_SOURCE_ROOT="$${XSH_SOURCE_ROOT:-$(XSH_SOURCE_ROOT)}" \
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" boot.xsh -- --userspace-e2e

boot-tailscale-test: ensure-host-xsh
	set -e; kernel_source="$${XSH_BOOT_KERNEL:-}"; \
	if [ -z "$$kernel_source" ] && [ -f "$(LAPUTA_INSTALLER_LOCAL_KERNEL)" ]; then \
	    kernel_source="$(LAPUTA_INSTALLER_LOCAL_KERNEL)"; \
	fi; \
	if [ -n "$$kernel_source" ]; then export XSH_BOOT_KERNEL="$$kernel_source"; fi; \
	XSH_BOOT_PROOF=0 \
	XSH_BOOT_TAILSCALE_PROBE=1 \
	XSH_BOOT_TAILSCALE_HOST_SSH_PROBE=$${XSH_BOOT_TAILSCALE_HOST_SSH_PROBE:-1} \
	XSH_BOOT_ATTACH=0 \
	XSH_BOOT_CONSOLE_TIMEOUT=$${XSH_BOOT_CONSOLE_TIMEOUT:-90} \
	XSH_BOOT_QEMU_DISPLAY=$${XSH_BOOT_QEMU_DISPLAY:-none} \
	XSH_SOURCE_ROOT="$${XSH_SOURCE_ROOT:-$(XSH_SOURCE_ROOT)}" \
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	$(BOOT_ARCH_ENV) \
	"$${XSH_HOST:-$(XSH_HOST)}" boot.xsh

proof-rootfs: ensure-build-essential-native
	docker build \
	    --build-arg PACKAGE_TOOLS_IMAGE=$(PACKAGE_TOOLS_IMAGE) \
	    --build-context packages=$(LAPUTA_PACKAGES_ROOT) \
	    -t laputa-xsh-proof \
	    -f Dockerfile.proof-rootfs .

installer-image: installer-image-aarch64

installer-image-aarch64: ensure-host-xsh
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" build-installer-aarch64.xsh

installer-image-amd64: ensure-host-xsh
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" build-installer-amd64.xsh

installer-image-x86_64: installer-image-amd64

installer-qemu-test: ensure-host-xsh
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" installer-qemu-test.xsh

installer-qemu-test-aarch64: installer-qemu-test

installer-qemu-test-amd64: ensure-host-xsh
	LAPUTA_INSTALLER_ARCH=x86_64 \
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" installer-qemu-test.xsh

installer-qemu-test-x86_64: installer-qemu-test-amd64

installer-qemu-manual: ensure-host-xsh
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" installer-qemu-manual.xsh

# Compatibility tag for the repo-backed scratch build-essential environment.
scratch-build-env: build-essential-native
	docker tag $(PACKAGE_TOOLS_IMAGE) laputa-scratch-build-env:latest

# Reusable scratch build-essential base with the common build tools installed from the mirror.
build-essential-native:
	docker buildx build \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    --build-arg LAPUTA_REPO_URL=$(LAPUTA_REPO_URL) \
	    --build-arg XSH_RELEASE=$(XSH_RELEASE) \
	    --build-arg XSH_RELEASE_ARCH=$(LAPUTA_PACKAGE_ARCH) \
	    --build-arg XSH_RELEASE_XSH_SHA256=$(XSH_RELEASE_XSH_SHA256) \
	    --build-arg XSH_RELEASE_XSHI_SHA256=$(XSH_RELEASE_XSHI_SHA256) \
	    --build-arg XSH_RELEASE_XSHT_SHA256=$(XSH_RELEASE_XSHT_SHA256) \
	    --build-arg XSH_CORE_SHA256=$(XSH_CORE_SHA256) \
	    --build-context packages=$(LAPUTA_PACKAGES_ROOT) \
	    --target build-essential-native-proof \
	    -f Dockerfile.build-essential-native \
	    .
	docker buildx build \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    --build-arg LAPUTA_REPO_URL=$(LAPUTA_REPO_URL) \
	    --build-arg XSH_RELEASE=$(XSH_RELEASE) \
	    --build-arg XSH_RELEASE_ARCH=$(LAPUTA_PACKAGE_ARCH) \
	    --build-arg XSH_RELEASE_XSH_SHA256=$(XSH_RELEASE_XSH_SHA256) \
	    --build-arg XSH_RELEASE_XSHI_SHA256=$(XSH_RELEASE_XSHI_SHA256) \
	    --build-arg XSH_RELEASE_XSHT_SHA256=$(XSH_RELEASE_XSHT_SHA256) \
	    --build-arg XSH_CORE_SHA256=$(XSH_CORE_SHA256) \
	    --build-context packages=$(LAPUTA_PACKAGES_ROOT) \
	    --target build-essential-native \
	    --load \
	    -t $(PACKAGE_TOOLS_IMAGE) \
	    -f Dockerfile.build-essential-native \
	    .
	docker tag $(PACKAGE_TOOLS_IMAGE) laputa-build-essential-native:latest
	docker tag $(PACKAGE_TOOLS_IMAGE) laputa-package-tools-base:latest
	docker tag $(PACKAGE_TOOLS_IMAGE) laputa-packages-builder:latest

packages-builder: build-essential-native

ensure-build-essential-native:
	@docker image inspect $(PACKAGE_TOOLS_IMAGE) >/dev/null 2>&1 || $(MAKE) build-essential-native

ensure-world-xsh:
	set -e; stage=$$(mktemp -d); trap 'rm -rf "$$stage"' EXIT; mkdir -p "$$stage/bin"; \
	for command_name in xsh xshi xsht; do \
	    case "$$command_name" in \
	        xsh) sha="$(XSH_RELEASE_XSH_SHA256)" ;; \
	        xshi) sha="$(XSH_RELEASE_XSHI_SHA256)" ;; \
	        xsht) sha="$(XSH_RELEASE_XSHT_SHA256)" ;; \
	    esac; \
	    dest="$$stage/bin/$$command_name"; \
	    curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/laputa-systems/xsh/releases/download/$(XSH_RELEASE)/$$command_name-$(XSH_RELEASE)-$(LAPUTA_PACKAGE_ARCH)-linux-musl" -o "$$dest"; \
	    echo "$$sha  $$dest" | sha256sum -c -; \
	    chmod 0755 "$$dest"; \
	done; \
	"$(DOCKER_SYNC_VOLUME)" "$(XSH_WORLD_VOLUME)" "$$stage" /opt/laputa/xsh-world "$(LAPUTA_DOCKER_PLATFORM)" "$(XSH_RELEASE_HELPER_IMAGE)"

package-test: ensure-package-docker-volumes
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_HOST=$(PACKAGE_TEST_XSH_HOST) \
	    -e PATH=/opt/laputa/xsh-world/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	    -e XSH_PM_REPO=file:///src/target/repo \
	    -e XSH_PM_PUBLIC_REPO=$(LAPUTA_REPO_URL) \
	    -e XSH_LINUX_KBUILD_TIMING=$(XSH_LINUX_KBUILD_TIMING) \
	    -e XSH_PM_REUSE_WORK=1 \
	    -e XSH_PM_REUSE_SET_ROOTS=1 \
	    -e XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN=$(XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN) \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    -v $(XSH_WORLD_VOLUME):/opt/laputa/xsh-world:ro \
	    -v $(XSH_CORE_VOLUME):/usr/lib/xsh/core:ro \
	    -v $(PACKAGE_TEST_CACHE_VOLUME):/src/target/repo/.out/remote-cache \
	    -v $(PACKAGE_TEST_WORK_VOLUME):/src/target/repo/.work \
	    -v $(PACKAGE_TEST_SET_ROOT_VOLUME):/src/target/repo/.set-root \
	    -v $(PACKAGE_TEST_SET_BUILD_ROOT_VOLUME):/src/target/repo/.set-build-root \
	    -v $(PACKAGE_TEST_SOURCE_MIRROR_VOLUME):/src/target/repo/.out/source-mirrors \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /opt/laputa/xsh-world/bin/xsh /src/packages/pm.xsh -- build-set \
	    /src/target/repo \
	    /src/packages/repo/$(PKGNAME)

package-deps-test: ensure-package-docker-volumes
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e LAPUTA_PACKAGE_ARCH=$(LAPUTA_PACKAGE_ARCH) \
	    -e XSH_PM_ARCH=$(LAPUTA_PACKAGE_ARCH) \
	    -e XSH_PM_TARGET_ARCH=$(LAPUTA_PACKAGE_ARCH) \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_HOST=/opt/laputa/xsh-world/bin/xsh \
	    -e PATH=/opt/laputa/xsh-world/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	    -e XSH_PM_REPO=file:///src/target/repo \
	    -e XSH_PM_PUBLIC_REPO=$(LAPUTA_REPO_URL) \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    -v $(XSH_WORLD_VOLUME):/opt/laputa/xsh-world:ro \
	    -v $(XSH_CORE_VOLUME):/usr/lib/xsh/core:ro \
	    -v $(PACKAGE_TEST_CACHE_VOLUME):/src/target/repo/.out/remote-cache \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /opt/laputa/xsh-world/bin/xsh /src/packages/pm.xsh -- build-set-deps \
	    /src/target/repo \
	    /src/packages/repo/$(PKGNAME)

linux-plan-only: ensure-package-docker-volumes
	status=0; docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_HOST=$(PACKAGE_TEST_XSH_HOST) \
	    -e PATH=/opt/laputa/xsh-world/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	    -e XSH_PM_REPO=file:///src/target/repo \
	    -e XSH_PM_PUBLIC_REPO=$(LAPUTA_REPO_URL) \
	    -e XSH_LINUX_KBUILD_TIMING=$(XSH_LINUX_KBUILD_TIMING) \
	    -e XSH_PM_REUSE_WORK=1 \
	    -e XSH_PM_REUSE_SET_ROOTS=1 \
	    -e XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN=$(XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN) \
	    -e XSH_LINUX_KBUILD_DISCOVER_JOBS=$(XSH_LINUX_KBUILD_DISCOVER_JOBS) \
	    -e XSH_LINUX_KBUILD_PROGRESS=$(XSH_LINUX_KBUILD_PROGRESS) \
	    -e XSH_LINUX_KBUILD_PROGRESS_EVERY=$(XSH_LINUX_KBUILD_PROGRESS_EVERY) \
	    -e XSH_LINUX_KBUILD_LOCAL_RECORDS=$(XSH_LINUX_KBUILD_LOCAL_RECORDS) \
	    -e XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE=$(XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE) \
	    -e XSH_LINUX_KBUILD_FORCE_DISCOVER=$(XSH_LINUX_KBUILD_FORCE_DISCOVER) \
	    -e XSH_LINUX_KBUILD_FORCE_ARCHIVES=$(XSH_LINUX_KBUILD_FORCE_ARCHIVES) \
	    -e XSH_LINUX_KBUILD_STOP_AFTER=plan \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    -v $(XSH_WORLD_VOLUME):/opt/laputa/xsh-world:ro \
	    -v $(XSH_CORE_VOLUME):/usr/lib/xsh/core:ro \
	    -v $(PACKAGE_TEST_CACHE_VOLUME):/src/target/repo/.out/remote-cache \
	    -v $(PACKAGE_TEST_WORK_VOLUME):/src/target/repo/.work \
	    -v $(PACKAGE_TEST_SET_ROOT_VOLUME):/src/target/repo/.set-root \
	    -v $(PACKAGE_TEST_SET_BUILD_ROOT_VOLUME):/src/target/repo/.set-build-root \
	    -v $(PACKAGE_TEST_SOURCE_MIRROR_VOLUME):/src/target/repo/.out/source-mirrors \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /opt/laputa/xsh-world/bin/xsh /src/packages/pm.xsh -- build-set \
	    /src/target/repo \
	    /src/packages/repo/linux || status=$$?; test "$$status" -eq 3

ensure-world-docker-volumes: ensure-build-essential-native ensure-world-xsh
	"$(DOCKER_SYNC_VOLUME)" "$(LAPUTA_PACKAGES_VOLUME)" "$(LAPUTA_PACKAGES_ROOT)" /src/packages "$(LAPUTA_DOCKER_PLATFORM)" "$(XSH_RELEASE_HELPER_IMAGE)"
	"$(DOCKER_SYNC_VOLUME)" "$(XSH_CORE_VOLUME)" "$(XSH_SOURCE_ROOT)/core" /usr/lib/xsh/core "$(LAPUTA_DOCKER_PLATFORM)" "$(XSH_RELEASE_HELPER_IMAGE)"
	docker volume create "$(WORLD_CACHE_VOLUME)" >/dev/null

ensure-package-docker-volumes: ensure-world-docker-volumes
	docker volume create "$(PACKAGE_TEST_CACHE_VOLUME)" >/dev/null
	docker volume create "$(PACKAGE_TEST_WORK_VOLUME)" >/dev/null
	docker volume create "$(PACKAGE_TEST_SET_ROOT_VOLUME)" >/dev/null
	docker volume create "$(PACKAGE_TEST_SET_BUILD_ROOT_VOLUME)" >/dev/null
	docker volume create "$(PACKAGE_TEST_SOURCE_MIRROR_VOLUME)" >/dev/null

LINUX_ORACLE_XSH_PLAN ?=
LINUX_ORACLE_XSH_ARCHIVE_PLAN ?=
LINUX_ORACLE_UPSTREAM_DRY_RUN ?=
LINUX_ORACLE_UPSTREAM_CACHE ?= tools/fixtures/linux-kbuild-oracle-aarch64.json
LINUX_ORACLE_SOURCE_ROOT ?=
LINUX_ORACLE_CONFIG ?=
LINUX_ORACLE_MATERIALIZED_MANIFEST ?=
LINUX_ORACLE_PREBUILT_OBJECTS ?= arch/arm64/kvm/hyp/nvhe/kvm_nvhe.o

linux-kbuild-oracle:
	test -n "$(LINUX_ORACLE_XSH_PLAN)" \
	    -a -n "$(LINUX_ORACLE_XSH_ARCHIVE_PLAN)" \
	    -a -n "$(LINUX_ORACLE_UPSTREAM_CACHE)" \
	    -a -n "$(LINUX_ORACLE_SOURCE_ROOT)" \
	    -a -n "$(LINUX_ORACLE_CONFIG)"
	oracle_args="--xsh-plan $(LINUX_ORACLE_XSH_PLAN) --xsh-archive-plan $(LINUX_ORACLE_XSH_ARCHIVE_PLAN) --upstream-cache $(LINUX_ORACLE_UPSTREAM_CACHE) --source-root $(LINUX_ORACLE_SOURCE_ROOT) --config $(LINUX_ORACLE_CONFIG)"; \
	for object in $(LINUX_ORACLE_PREBUILT_OBJECTS); do oracle_args="$$oracle_args --prebuilt-object $$object"; done; \
	if [ -n "$(LINUX_ORACLE_MATERIALIZED_MANIFEST)" ]; then oracle_args="$$oracle_args --materialized-manifest $(LINUX_ORACLE_MATERIALIZED_MANIFEST)"; fi; \
	if [ -n "$(LINUX_ORACLE_UPSTREAM_DRY_RUN)" ]; then oracle_args="$$oracle_args --upstream-dry-run $(LINUX_ORACLE_UPSTREAM_DRY_RUN)"; fi; \
	python3 tools/linux-kbuild-oracle.py $$oracle_args

pkgconf-test:
	$(MAKE) package-test PKGNAME=pkgconf

samurai-test:
	$(MAKE) package-test PKGNAME=samurai

cmake-test:
	$(MAKE) package-test PKGNAME=cmake

dropbear-test:
	$(MAKE) package-test PKGNAME=dropbear

tmux-test:
	$(MAKE) package-test PKGNAME=tmux

linux-pam-test:
	$(MAKE) package-test PKGNAME=linux-pam

sudo-rs-test:
	$(MAKE) package-test PKGNAME=sudo-rs

iptables-test:
	$(MAKE) package-test PKGNAME=iptables

tailscale-test:
	$(MAKE) package-test PKGNAME=tailscale

less-test:
	$(MAKE) package-test PKGNAME=less

dwl-foot-minimal-test: ensure-build-essential-native
	docker build --build-arg PACKAGE_TOOLS_IMAGE=$(PACKAGE_TOOLS_IMAGE) \
	    --build-context packages=$(LAPUTA_PACKAGES_ROOT) \
	    -t laputa-dwl-foot-minimal-proof \
	    -f Dockerfile.dwl-foot-minimal .

ensure-dwl-foot-minimal-proof:
	@docker image inspect laputa-dwl-foot-minimal-proof:latest >/dev/null 2>&1 || $(MAKE) dwl-foot-minimal-test

dwl-foot-minimal-qemu-debug: ensure-dwl-foot-minimal-proof
	XSH_BOOT_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_DEBUG=1 \
	XSH_BOOT_ATTACH=0 \
	XSH_BOOT_ROOTFS_IMAGE=$${XSH_BOOT_ROOTFS_IMAGE:-laputa-dwl-foot-minimal-proof} \
	XSH_BOOT_CONSOLE_TIMEOUT=$${XSH_BOOT_CONSOLE_TIMEOUT:-40} \
	xsh boot.xsh

waterfox-test: ensure-dwl-foot-minimal-proof
	docker build --build-arg PACKAGE_TOOLS_IMAGE=$(PACKAGE_TOOLS_IMAGE) \
	    --build-arg DWL_FOOT_IMAGE=laputa-dwl-foot-minimal-proof:latest \
	    --build-context packages=$(LAPUTA_PACKAGES_ROOT) \
	    -t laputa-waterfox-proof \
	    -f Dockerfile.waterfox .

ensure-waterfox-proof:
	@docker image inspect laputa-waterfox-proof:latest >/dev/null 2>&1 || $(MAKE) waterfox-test

waterfox-qemu-test: ensure-waterfox-proof ensure-proof-kernel
	XSH_BOOT_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_BROWSER_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_AUDIO_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_CLIPBOARD_PROOF=1 \
	XSH_BOOT_WATERFOX_QEMU_MESA_PROOF=1 \
	XSH_BOOT_ATTACH=0 \
	XSH_BOOT_ROOTFS_IMAGE=$${XSH_BOOT_ROOTFS_IMAGE:-laputa-waterfox-proof} \
	XSH_BOOT_QEMU_DISPLAY=$${XSH_BOOT_QEMU_DISPLAY:-none} \
	XSH_BOOT_QEMU_GPU_DEVICE=$${XSH_BOOT_QEMU_GPU_DEVICE:-virtio} \
	XSH_BOOT_CONSOLE_TIMEOUT=$${XSH_BOOT_CONSOLE_TIMEOUT:-320} \
	xsh boot.xsh

PKGNAME ?= pkgconf
PACKAGE_TOOLS_IMAGE ?= laputa-bootstrapped-build-essential-native:latest
PACKAGE_TEST_XSH_HOST ?= /opt/laputa/xsh-world/bin/xsh
XSH_LINUX_KBUILD_TIMING ?= 1
XSH_LINUX_KBUILD_PROGRESS ?=
XSH_LINUX_KBUILD_PROGRESS_EVERY ?= 100
XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN ?= 1
XSH_LINUX_KBUILD_DISCOVER_JOBS ?= 64
XSH_LINUX_KBUILD_LOCAL_RECORDS ?= 1
XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE ?= 1
XSH_LINUX_KBUILD_FORCE_DISCOVER ?=
XSH_LINUX_KBUILD_FORCE_ARCHIVES ?=
LAPUTA_REPO_URL ?= https://laputa.17166969.xyz
LAPUTA_MIRROR_URL ?= https://laputa.17166969.xyz
LAPUTA_INSTALLER_LOCAL_KERNEL ?= $(CURDIR)/target/laputa-installer/local-linux-aarch64.Image
HOST_JOBS ?= $(shell command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
LINUX_KBUILD_JOBS ?= $(HOST_JOBS)
# don't exhaust fds (inside orbstack on macos)
WORLD_JOBS ?= 4
WORLD_TO_TRANCHE ?=
LINUX_SOURCES ?=

world-build: ensure-world-docker-volumes
	set -e; if [ -f .env ]; then set -a; . ./.env; set +a; fi; token="$${LAPUTA_TOKEN:-}"; \
	extra=""; \
	if [ -n "$(WORLD_TO_TRANCHE)" ]; then extra="$$extra --to-tranche $(WORLD_TO_TRANCHE)"; fi; \
	if [ "$(WORLD_UPLOAD)" = "1" ]; then extra="$$extra --upload"; fi; \
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_HOST=/opt/laputa/xsh-world/bin/xsh \
	    -e PATH=/opt/laputa/xsh-world/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	    -e XSH_PM_REPO="$(LAPUTA_MIRROR_URL)" \
	    -e XSH_PM_PUBLIC_REPO="$(LAPUTA_MIRROR_URL)" \
	    -e RUST_MIN_STACK="$${RUST_MIN_STACK:-67108864}" \
	    -e LAPUTA_TOKEN="$$token" \
	    -e MAKEFLAGS="$${MAKEFLAGS:--s -j$(LINUX_KBUILD_JOBS)}" \
	    -e XSH_LINUX_KBUILD_JOBS="$${XSH_LINUX_KBUILD_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	    -e XSH_LINUX_KBUILD_DISCOVER_JOBS="$${XSH_LINUX_KBUILD_DISCOVER_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	    -e XSH_LINUX_KBUILD_PROGRESS="$${XSH_LINUX_KBUILD_PROGRESS:-1}" \
	    -e XSH_LINUX_KBUILD_PROGRESS_EVERY="$${XSH_LINUX_KBUILD_PROGRESS_EVERY:-100}" \
	    -e XSH_LINUX_KBUILD_TIMING="$${XSH_LINUX_KBUILD_TIMING:-1}" \
	    -e XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN="$${XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN:-1}" \
	    -e XSH_LINUX_KBUILD_FORCE_DISCOVER="$${XSH_LINUX_KBUILD_FORCE_DISCOVER:-}" \
	    -e XSH_LINUX_KBUILD_FORCE_ARCHIVES="$${XSH_LINUX_KBUILD_FORCE_ARCHIVES:-}" \
	    -e XSH_LINUX_KBUILD_REUSE_ARCHIVES="$${XSH_LINUX_KBUILD_REUSE_ARCHIVES:-}" \
	    -e XSH_LINUX_KBUILD_TRUST_PLAN_CACHE="$${XSH_LINUX_KBUILD_TRUST_PLAN_CACHE:-}" \
	    -e XSH_MAKE_PROGRESS="$${XSH_MAKE_PROGRESS:-1}" \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    -v $(XSH_WORLD_VOLUME):/opt/laputa/xsh-world:ro \
	    -v $(XSH_CORE_VOLUME):/usr/lib/xsh/core:ro \
	    -v $(WORLD_CACHE_VOLUME):/root/.cache/laputa \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /opt/laputa/xsh-world/bin/xsh /src/packages/pm.xsh -- world-plan \
	    /src/packages/repo \
	    --arch $(LAPUTA_PACKAGE_ARCH) \
	    --build \
	    --jobs $(WORLD_JOBS) \
	    $$extra

world-build-aarch64: ensure-host-xsh
	set -e; if [ -f .env ]; then set -a; . ./.env; set +a; fi; token="$${LAPUTA_TOKEN:-}"; \
	case "$$(uname -m)" in x86_64|amd64) ;; *) echo "world-build-aarch64 native cross build requires an amd64 host" >&2; exit 1 ;; esac; \
	mkdir -p "$$HOME/.cache/laputa"; extra=""; \
	if [ -n "$(WORLD_TO_TRANCHE)" ]; then extra="$$extra --to-tranche $(WORLD_TO_TRANCHE)"; fi; \
	if [ "$(WORLD_UPLOAD)" = "1" ]; then extra="$$extra --upload"; fi; \
	XSH_HOST="$(XSH_HOST)" \
	XSH_MODULE_PATH="$(LAPUTA_PACKAGES_ROOT)" \
	XSH_PM_REPO="$(LAPUTA_MIRROR_URL)" \
	XSH_PM_PUBLIC_REPO="$(LAPUTA_MIRROR_URL)" \
	XSH_PM_ARCH="aarch64" \
	XSH_PM_BUILD_ARCH="x86_64" \
	XSH_PM_TARGET_ARCH="aarch64" \
	XSH_PM_NATIVE_CROSS="1" \
	LAPUTA_TOKEN="$$token" \
	RUST_MIN_STACK="$${RUST_MIN_STACK:-67108864}" \
	XSH_LINUX_KBUILD_PLAN_CACHE_DIR="$${XSH_LINUX_KBUILD_PLAN_CACHE_DIR:-$${HOME}/.cache/laputa/linux-kbuild-aarch64}" \
	MAKEFLAGS="$${MAKEFLAGS:--s -j$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_JOBS="$${XSH_LINUX_KBUILD_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_DISCOVER_JOBS="$${XSH_LINUX_KBUILD_DISCOVER_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_PROGRESS="$${XSH_LINUX_KBUILD_PROGRESS:-1}" \
	XSH_LINUX_KBUILD_PROGRESS_EVERY="$${XSH_LINUX_KBUILD_PROGRESS_EVERY:-100}" \
	XSH_LINUX_KBUILD_TIMING="$${XSH_LINUX_KBUILD_TIMING:-1}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN="$${XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN:-1}" \
	XSH_LINUX_KBUILD_FORCE_DISCOVER="$${XSH_LINUX_KBUILD_FORCE_DISCOVER:-}" \
	XSH_LINUX_KBUILD_FORCE_ARCHIVES="$${XSH_LINUX_KBUILD_FORCE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVES="$${XSH_LINUX_KBUILD_REUSE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_TRUST_PLAN_CACHE="$${XSH_LINUX_KBUILD_TRUST_PLAN_CACHE:-}" \
	XSH_MAKE_PROGRESS="$${XSH_MAKE_PROGRESS:-1}" \
	"$(XSH_HOST)" "$(LAPUTA_PACKAGES_ROOT)/pm.xsh" -- world-plan \
	    "$(LAPUTA_PACKAGES_ROOT)/repo" \
	    --arch aarch64 \
	    --build \
	    --jobs $(WORLD_JOBS) \
	    $$extra

world-build-amd64: ensure-host-xsh-release
	set -e; \
	case "$$(uname -m)" in x86_64|amd64) ;; *) echo "world-build-amd64 requires an amd64 host" >&2; exit 1 ;; esac; \
	if [ "$$(id -u)" != "0" ]; then \
	    if command -v doas >/dev/null 2>&1; then \
	        exec doas env PATH="$$PATH" $(MAKE) _world-build-amd64 \
	            WORLD_JOBS="$(WORLD_JOBS)" \
	            WORLD_TO_TRANCHE="$(WORLD_TO_TRANCHE)" \
	            WORLD_UPLOAD="$(WORLD_UPLOAD)" \
	            LINUX_KBUILD_JOBS="$(LINUX_KBUILD_JOBS)"; \
	    elif command -v sudo >/dev/null 2>&1; then \
	        exec sudo -E $(MAKE) _world-build-amd64 \
	            WORLD_JOBS="$(WORLD_JOBS)" \
	            WORLD_TO_TRANCHE="$(WORLD_TO_TRANCHE)" \
	            WORLD_UPLOAD="$(WORLD_UPLOAD)" \
	            LINUX_KBUILD_JOBS="$(LINUX_KBUILD_JOBS)"; \
	    else \
	        echo "world-build-amd64 requires root for chroot; run with doas env PATH=\"\$$PATH\" or sudo -E" >&2; exit 1; \
	    fi; \
	fi; \
	$(MAKE) _world-build-amd64

.PHONY: _world-build-amd64
_world-build-amd64:
	set -e; if [ -f .env ]; then set -a; . ./.env; set +a; fi; token="$${LAPUTA_TOKEN:-}"; \
	mkdir -p "$$HOME/.cache/laputa"; extra=""; \
	if [ -n "$(WORLD_TO_TRANCHE)" ]; then extra="$$extra --to-tranche $(WORLD_TO_TRANCHE)"; fi; \
	if [ "$(WORLD_UPLOAD)" = "1" ]; then extra="$$extra --upload"; fi; \
	XSH_HOST="$(XSH_HOST_RELEASE_BIN_DIR)/xsh" \
	XSH_MODULE_PATH="$(LAPUTA_PACKAGES_ROOT)" \
	XSH_PM_REPO="$(LAPUTA_MIRROR_URL)" \
	XSH_PM_PUBLIC_REPO="$(LAPUTA_MIRROR_URL)" \
	LAPUTA_TOKEN="$$token" \
	RUST_MIN_STACK="$${RUST_MIN_STACK:-67108864}" \
	MAKEFLAGS="$${MAKEFLAGS:--s -j$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_JOBS="$${XSH_LINUX_KBUILD_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_DISCOVER_JOBS="$${XSH_LINUX_KBUILD_DISCOVER_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_PROGRESS="$${XSH_LINUX_KBUILD_PROGRESS:-1}" \
	XSH_LINUX_KBUILD_PROGRESS_EVERY="$${XSH_LINUX_KBUILD_PROGRESS_EVERY:-100}" \
	XSH_LINUX_KBUILD_TIMING="$${XSH_LINUX_KBUILD_TIMING:-1}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN="$${XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN:-1}" \
	XSH_LINUX_KBUILD_FORCE_DISCOVER="$${XSH_LINUX_KBUILD_FORCE_DISCOVER:-}" \
	XSH_LINUX_KBUILD_FORCE_ARCHIVES="$${XSH_LINUX_KBUILD_FORCE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVES="$${XSH_LINUX_KBUILD_REUSE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_TRUST_PLAN_CACHE="$${XSH_LINUX_KBUILD_TRUST_PLAN_CACHE:-}" \
	XSH_MAKE_PROGRESS="$${XSH_MAKE_PROGRESS:-1}" \
	"$(XSH_HOST_RELEASE_BIN_DIR)/xsh" "$(LAPUTA_PACKAGES_ROOT)/pm.xsh" -- world-plan \
	    "$(LAPUTA_PACKAGES_ROOT)/repo" \
	    --arch x86_64 \
	    --build \
	    --jobs $(WORLD_JOBS) \
	    $$extra

world-smoke-amd64: ensure-host-xsh
	set -e; \
	LAPUTA_PACKAGE_ARCH=x86_64 \
	LAPUTA_REPO_URL="$(LAPUTA_MIRROR_URL)" \
	XSH_BOOT_ATTACH=0 \
	XSH_BOOT_QEMU_ACCEL=$${XSH_BOOT_QEMU_ACCEL:-tcg} \
	XSH_BOOT_QEMU_CPU=$${XSH_BOOT_QEMU_CPU:-max} \
	XSH_LINUX_LOOP_TIMEOUT=$${XSH_LINUX_LOOP_TIMEOUT:-45} \
	XSH_SOURCE_ROOT="$${XSH_SOURCE_ROOT:-$(XSH_SOURCE_ROOT)}" \
	XSH_HOST="$${XSH_HOST:-$(XSH_HOST)}" \
	"$${XSH_HOST:-$(XSH_HOST)}" boot.xsh -- --linux-only

amd64-package-test: ensure-host-xsh-release
	set -e; \
	if [ "$$(id -u)" != "0" ]; then echo "amd64-package-test requires root for chroot; run with doas" >&2; exit 1; fi; \
	mkdir -p "$$HOME/.cache/laputa"; \
	mkdir -p "$$HOME/.cache/laputa/linux-kbuild"; \
	rm -f "$$HOME/.cache/laputa/amd64-package-test/index.json"; \
	mkdir -p "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/var/cache/laputa/linux-kbuild"; \
	cp -a "$$HOME/.cache/laputa/linux-kbuild/." "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/var/cache/laputa/linux-kbuild/" 2>/dev/null || true; \
	trap 'mkdir -p "$$HOME/.cache/laputa/linux-kbuild"; cp -a "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/var/cache/laputa/linux-kbuild/." "$$HOME/.cache/laputa/linux-kbuild/" 2>/dev/null || true' EXIT; \
	ln -sf /usr/lib/ld-musl-x86_64.so.1 "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/lib/ld-musl-x86_64.so.1" 2>/dev/null || true; \
	ln -sf /usr/bin/clang "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/usr/bin/as" 2>/dev/null || true; \
	ln -sf /usr/lib/ld-musl-x86_64.so.1 "$$HOME/.cache/laputa/amd64-package-test/.set-root/lib/ld-musl-x86_64.so.1" 2>/dev/null || true; \
	rm -rf "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/usr/lib/pm/pm"; \
	mkdir -p "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/usr/lib/pm"; \
	cp -a "$(LAPUTA_PACKAGES_ROOT)/pm" "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/usr/lib/pm/pm"; \
	cp "$(LAPUTA_PACKAGES_ROOT)/pm.xsh" "$$HOME/.cache/laputa/amd64-package-test/.set-build-root/usr/lib/pm/pm.xsh"; \
	XSH_PM_BUILD_CHROOT="$${XSH_PM_BUILD_CHROOT:-1}" \
	XSH_PM_REUSE_WORK="$${XSH_PM_REUSE_WORK:-1}" \
	XSH_PM_REUSE_SET_ROOTS="$${XSH_PM_REUSE_SET_ROOTS:-1}" \
	XSH_HOST="$(XSH_HOST_RELEASE_BIN_DIR)/xsh" \
	XSH_MODULE_PATH="$(LAPUTA_PACKAGES_ROOT)" \
	XSH_PM_REPO="$(LAPUTA_MIRROR_URL)" \
	XSH_PM_PUBLIC_REPO="$(LAPUTA_MIRROR_URL)" \
	XSH_LINUX_KBUILD_PROGRESS=1 \
	XSH_LINUX_KBUILD_PROGRESS_EVERY=$${XSH_LINUX_KBUILD_PROGRESS_EVERY:-100} \
	MAKEFLAGS="$${MAKEFLAGS:--s -j$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_JOBS="$${XSH_LINUX_KBUILD_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_DISCOVER_JOBS="$${XSH_LINUX_KBUILD_DISCOVER_JOBS:-$(LINUX_KBUILD_JOBS)}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN="$${XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN:-1}" \
	XSH_LINUX_KBUILD_LOCAL_RECORDS="$${XSH_LINUX_KBUILD_LOCAL_RECORDS:-}" \
	XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE="$${XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE:-}" \
	XSH_LINUX_KBUILD_FORCE_DISCOVER="$${XSH_LINUX_KBUILD_FORCE_DISCOVER:-}" \
	XSH_LINUX_KBUILD_REUSE_ARCHIVES="$${XSH_LINUX_KBUILD_REUSE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_FORCE_ARCHIVES="$${XSH_LINUX_KBUILD_FORCE_ARCHIVES:-}" \
	XSH_LINUX_KBUILD_ONLY="$${XSH_LINUX_KBUILD_ONLY:-}" \
	XSH_LINUX_KBUILD_STOP_AFTER="$${XSH_LINUX_KBUILD_STOP_AFTER:-}" \
	XSH_LINUX_KBUILD_TIMING="$${XSH_LINUX_KBUILD_TIMING:-1}" \
	XSH_LINUX_KBUILD_USE_PLAN="$${XSH_LINUX_KBUILD_USE_PLAN:-}" \
	XSH_LINUX_KBUILD_USE_PLAN_TEXT="$${XSH_LINUX_KBUILD_USE_PLAN_TEXT:-}" \
	XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE="$${XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE:-}" \
	XSH_LINUX_KBUILD_TRUST_PLAN_CACHE="$(XSH_LINUX_KBUILD_TRUST_PLAN_CACHE)" \
	"$(XSH_HOST_RELEASE_BIN_DIR)/xsh" "$(LAPUTA_PACKAGES_ROOT)/pm.xsh" -- build-set \
	    "$$HOME/.cache/laputa/amd64-package-test" \
	    "$(LAPUTA_PACKAGES_ROOT)/repo/$(PKGNAME)"

linux-amd64-config linux-amd64-prepare-proof linux-amd64-discover-proof linux-amd64-plan-proof linux-amd64-compile-proof linux-amd64-link-proof linux-amd64-package-proof linux-amd64-object linux-amd64-sources linux-amd64-cache linux-amd64-kconfig-proof: ensure-host-xsh
	set -e; \
	target="$@"; mode="$${target#linux-amd64-}"; mode="$${mode%-proof}"; \
	if [ "$$target" = "linux-amd64-object" ]; then mode="object $(LINUX_SOURCES)"; fi; \
	if [ "$$target" = "linux-amd64-sources" ]; then mode="sources $(LINUX_SOURCES)"; fi; \
	if [ "$$target" = "linux-amd64-kconfig-proof" ]; then mode="kconfig-proof"; fi; \
	XSH_MODULE_PATH="$(LAPUTA_PACKAGES_ROOT)" \
	XSH_HOST="$(XSH_HOST)" \
	LAPUTA_MIRROR_URL="$(LAPUTA_MIRROR_URL)" \
	LINUX_KBUILD_JOBS="$(LINUX_KBUILD_JOBS)" \
	"$(XSH_HOST)" "$(CURDIR)/linux-iteration.xsh" $$mode

package-publish: ensure-world-docker-volumes
	set -e; if [ -f .env ]; then set -a; . ./.env; set +a; fi; token="$${LAPUTA_TOKEN:-}"; \
	test -n "$$token"; \
	docker run --rm \
	    --platform $(LAPUTA_DOCKER_PLATFORM) \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_PM_REPO=$(LAPUTA_MIRROR_URL) \
	    -e XSH_PM_PUBLIC_REPO=$(LAPUTA_MIRROR_URL) \
	    -e LAPUTA_TOKEN="$$token" \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /bin/xsh /src/packages/pm.xsh -- build-upload-set \
	    /src/target/repo \
	    /src/packages/repo/$(PKGNAME)

package-publish-userspace-arm64: ensure-world-docker-volumes
	set -e; if [ -f .env ]; then set -a; . ./.env; set +a; fi; token="$${LAPUTA_TOKEN:-}"; \
	test -n "$$token"; \
	docker run --rm \
	    --platform linux/arm64 \
	    -e XSH_MODULE_PATH=/src/packages \
	    -e XSH_PM_REPO=$(LAPUTA_MIRROR_URL) \
	    -e XSH_PM_PUBLIC_REPO=$(LAPUTA_MIRROR_URL) \
	    -e LAPUTA_TOKEN="$$token" \
	    -v $(LAPUTA_PACKAGES_VOLUME):/src/packages:ro \
	    $(PACKAGE_TOOLS_IMAGE) \
	    /bin/xsh /src/packages/pm.xsh -- build-upload-set \
	    /src/target/repo \
	    /src/packages/repo/xinit \
	    /src/packages/repo/baselayout \
	    /src/packages/repo/linux-pam \
	    /src/packages/repo/sudo-rs \
	    /src/packages/repo/dropbear \
	    /src/packages/repo/tailscale \
	    /src/packages/repo/seatd
