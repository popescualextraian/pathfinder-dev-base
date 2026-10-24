IMAGE ?= agentic-dev-base:local
SHELL_SOURCES = $(wildcard bin/agentic lib/host/*.sh image/*.sh image/lib/*.sh image/start.d/*.sh \
  image/tools/*.sh image/bin/* image/profile.d/*.sh derive/*.sh tools/*.sh tests/image/*.sh \
  image/task/*.sh image/task/lib/*.sh tests/e2e/*.sh image/cost/snapshot image/cost/ccusage-collector)

.DEFAULT_GOAL := test
.PHONY: test lint build smoke

BRIDGE_DEPS = bridge/node_modules/.package-lock.json
ARCH_DEPS = image/arch/node_modules/.package-lock.json

$(BRIDGE_DEPS): bridge/package-lock.json
	cd bridge && npm ci

$(ARCH_DEPS): image/arch/package-lock.json
	cd image/arch && npm ci

test: $(BRIDGE_DEPS) $(ARCH_DEPS)
	bats -r tests/bats
	cd bridge && npm test

lint: $(BRIDGE_DEPS) $(ARCH_DEPS)
	shellcheck -x $(SHELL_SOURCES)
	jq empty schema/*.json skills/architect/schema/*.json
	tools/gen-config-docs.sh --check
	tools/leak-check.sh
	cd bridge && npm run lint

build:
	bin/agentic build-base

smoke: build
	IMAGE=$(IMAGE) bash tests/image/smoke.sh
