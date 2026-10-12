IMAGE ?= agentic-dev-base:local
SHELL_SOURCES = $(wildcard bin/agentic lib/host/*.sh image/*.sh image/lib/*.sh image/start.d/*.sh \
  image/tools/*.sh image/bin/* image/profile.d/*.sh derive/*.sh tools/*.sh tests/image/*.sh \
  image/task/*.sh image/task/lib/*.sh tests/e2e/*.sh)

.PHONY: test lint build smoke

test:
	bats -r tests/bats

lint:
	shellcheck -x $(SHELL_SOURCES)
	jq empty schema/agentic.schema.json
	tools/gen-config-docs.sh --check
	tools/leak-check.sh

build:
	bin/agentic build-base

smoke: build
	IMAGE=$(IMAGE) bash tests/image/smoke.sh
