# The typed profile CLI is the sole core-system orchestration surface.
# Installer aliases remain isolated because installer workflows are not part of
# the qemu-dwl-foot profile lifecycle.

XSH_SOURCE_ROOT ?= $(abspath $(CURDIR)/../xsh)
XSH_HOST ?= $(XSH_SOURCE_ROOT)/target/debug/xsh
LAPUTA_PACKAGES_ROOT ?= $(abspath $(CURDIR)/../packages)

.PHONY: plan build test boot clean pm-test \
	installer-image installer-image-aarch64 installer-image-amd64 installer-image-x86_64 \
	installer-qemu-test installer-qemu-test-aarch64 installer-qemu-test-amd64 installer-qemu-test-x86_64 \
	installer-qemu-manual

plan:
	$(XSH_HOST) laputa.xsh -- plan qemu-dwl-foot

build:
	$(XSH_HOST) laputa.xsh -- build qemu-dwl-foot

test:
	$(XSH_HOST) laputa.xsh -- test qemu-dwl-foot

boot:
	$(XSH_HOST) laputa.xsh -- boot qemu-dwl-foot

clean:
	$(XSH_HOST) laputa.xsh -- clean qemu-dwl-foot

pm-test:
	$(MAKE) -C $(LAPUTA_PACKAGES_ROOT) test

installer-image: installer-image-aarch64

installer-image-aarch64:
	$(XSH_HOST) build-installer-aarch64.xsh

installer-image-amd64:
	$(XSH_HOST) build-installer-amd64.xsh

installer-image-x86_64: installer-image-amd64

installer-qemu-test: installer-qemu-test-aarch64

installer-qemu-test-aarch64:
	$(XSH_HOST) installer-qemu-test.xsh

installer-qemu-test-amd64:
	LAPUTA_INSTALLER_ARCH=x86_64 $(XSH_HOST) installer-qemu-test.xsh

installer-qemu-test-x86_64: installer-qemu-test-amd64

installer-qemu-manual:
	$(XSH_HOST) installer-qemu-manual.xsh
