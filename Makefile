IMAGE ?= agentic-dev-base:local
SHELL_SOURCES = $(wildcard bin/agentic lib/host/*.sh image/*.sh image/lib/*.sh image/start.d/*.sh \
  image/tools/*.sh image/bin/* image/profile.d/*.sh derive/*.sh tools/*.sh tests/image/*.sh)

.PHONY: test lint build smoke

test:
	bats -r tests/bats

lint:
	shellcheck -x $(SHELL_SOURCES)
	tools/leak-check.sh

build:
	bin/agentic build-base

smoke: build
	IMAGE=$(IMAGE) bash tests/image/smoke.sh
