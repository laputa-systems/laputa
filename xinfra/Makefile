SHELL := /bin/sh

XSH_ROOT ?= ../../xsh
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
TRIPLE ?= aarch64-apple-darwin
else ifeq ($(UNAME_M),x86_64)
TRIPLE ?= x86_64-unknown-linux-musl
else
TRIPLE ?= aarch64-unknown-linux-musl
endif

XSH ?= $(XSH_ROOT)/target/$(TRIPLE)/release/xsh
XSHT ?= $(XSH_ROOT)/target/$(TRIPLE)/release/xsht
LIMA_HOME ?= $(CURDIR)/.work/fixtures/lima
PYINFRA_VENV ?= $(CURDIR)/.work/oracle/venv
PYINFRA ?= $(PYINFRA_VENV)/bin/pyinfra
PREFIX ?= /usr/local

export LIMA_HOME

.PHONY: check test fixtures verify down oracle differential integration package install perf

check:
	$(XSHT) check

test:
	$(XSHT) test

fixtures:
	$(XSH) dev/fixtures.xsh up

verify:
	$(XSH) dev/fixtures.xsh verify

down:
	$(XSH) dev/fixtures.xsh down

oracle:
	@test -x $(PYINFRA) || { uv venv --python 3.13 $(PYINFRA_VENV) && uv pip install --python $(PYINFRA_VENV)/bin/python -r dev/oracle/requirements.txt; }

differential: oracle
	XINFRA_PYINFRA=$(PYINFRA) $(XSH) dev/fixtures.xsh exec --cwd $(CURDIR) -- $(XSH) dev/differential.xsh

integration:
	XINFRA_XSH="$(abspath $(XSH))" $(XSH) dev/fixtures.xsh exec --cwd $(CURDIR) -- $(XSH) dev/integration.xsh --case all

package:
	$(XSH) dev/package.xsh

perf: oracle
	XINFRA_XSH=$(abspath $(XSH)) XINFRA_PYINFRA=$(PYINFRA) $(XSH) dev/fixtures.xsh exec --cwd $(CURDIR) -- $(XSH) dev/perf.xsh

install: package
	@set -e; \
	rm -rf .work/tmp/install-src; \
	mkdir -p .work/tmp/install-src; \
	tarball=$$(ls -t .work/dist/xinfra-*.tar.gz | head -1); \
	tar -xzf "$$tarball" -C .work/tmp/install-src; \
	src=$$(ls -d .work/tmp/install-src/xinfra-*/ | head -1); \
	sh "$$src/install.sh" "$(PREFIX)"
