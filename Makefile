# Run `make help` to display help
.DEFAULT_GOAL := $(or $(EVY_DEFAULT_GOAL),help)

# --- Global -------------------------------------------------------------------
O = out
COVERAGE = 70
VERSION ?= $(shell git describe --tags --dirty  --always)
GOFILES = $(shell find . -name '*.go')

## Build, test, check coverage and lint
all: build-full test lint
	@if [ -e .git/rebase-merge ]; then git --no-pager log -1 --pretty='%h %s'; fi
	@echo '$(COLOUR_GREEN)Success$(COLOUR_NORMAL)'

test: test-go test-tiny test-cli check-coverage

lint: lint-go lint-sh check-prettier check-style check-fmt-evy

## Full clean build and up-to-date checks as run on CI
ci: clean check-uptodate all

check-uptodate: tidy fmt doc docs
	test -z "$$(git status --porcelain)" || { git status; false; }

## Remove generated files
clean::
	-rm -rf $(O)

.PHONY: all check-uptodate ci test lint clean

# --- Build --------------------------------------------------------------------
GO_LDFLAGS = -X main.version=$(VERSION)
CMDS = .

## Build full evy binaries
build-full: embed | $(O)
	go build -tags full -o $(O) -ldflags='$(GO_LDFLAGS)' $(CMDS)

## Build evy binaries without web content embedded
build-go: $(O)
	go build -o $(O) -ldflags='$(GO_LDFLAGS)' $(CMDS)

## Build and install binaries in $GOBIN
install-full: embed
	go install -tags full -ldflags='$(GO_LDFLAGS)' $(CMDS)

## Build and install binaries without embedded frontend in $GOBIN
install:
	go install -ldflags='$(GO_LDFLAGS)' $(CMDS)

# Use `go version` to ensure the right go version is installed when using tinygo.
go-version:
	go version

## Build with tinygo targeting wasm
# optimise for size, see https://www.fermyon.com/blog/optimizing-tinygo-wasm
build-tiny: go-version | $(O)
	GOOS=wasip1 GOARCH=wasm tinygo build -o $(O)/evy-unopt.wasm -no-debug -ldflags='$(GO_LDFLAGS)' -stack-size=512kb ./pkg/wasm
	wasm-opt -O3 $(O)/evy-unopt.wasm -o frontend/module/evy.wasm
	cp -f $$(tinygo env TINYGOROOT)/targets/wasm_exec.js frontend/module/
	echo '{ "version": "$(VERSION)" }' | jq > frontend/version.json

## Prepare frontend assets to be embedded into the binary
embed: build-tiny | $(O)
	rm -rf $(O)/embed
	go run ./build-tools/site-gen frontend $(O)/embed

## Tidy go modules with "go mod tidy"
tidy:
	go mod tidy

## Format all go files with gofumpt, a stricter gofmt
fmt:
	gofumpt -w $(GOFILES)

clean::
	-rm -f frontend/module/evy.wasm
	-rm -f frontend/module/wasm_exec.js
	-rm -f frontend/version.json

.PHONY: build-full build-go build-tiny embed go-version install install-full tidy

# --- Test ---------------------------------------------------------------------
COVERFILE = $(O)/coverage.txt
EXPORTDIR = $(O)/export-test

## Run non-tinygo tests and generate a coverage file
test-go: | $(O)
	go test -coverprofile=$(COVERFILE) ./...

## Test evy CLI
test-cli: build-full
	rm -rf $(EXPORTDIR)
	$(O)/evy serve export $(EXPORTDIR)
	test -f $(EXPORTDIR)/index.html
	test -f $(EXPORTDIR)/play/module/evy.wasm
	test ! -L $(EXPORTDIR)/play/module/evy.wasm

## Run tinygo tests
test-tiny: go-version | $(O)
	tinygo test ./...

## Check that test coverage meets the required level
check-coverage: test-go
	@go tool cover -func=$(COVERFILE) | $(CHECK_COVERAGE) || $(FAIL_COVERAGE)

## Show test coverage in your browser
cover: test-go
	go tool cover -html=$(COVERFILE)

CHECK_COVERAGE = awk -F '[ \t%]+' '/^total:/ {print; if ($$3 < $(COVERAGE)) exit 1}'
FAIL_COVERAGE = { echo '$(COLOUR_RED)FAIL - Coverage below $(COVERAGE)%$(COLOUR_NORMAL)'; exit 1; }

.PHONY: check-coverage cover test-cli test-go test-tiny

# --- Lint ---------------------------------------------------------------------
EVY_FILES = $(shell find frontend/play/samples -name '*.evy')

## Lint go source code
lint-go:
	golangci-lint run

## Format evy sample code
fmt-evy:
	go run . fmt --write $(EVY_FILES)

check-fmt-evy:
	go run . fmt --check $(EVY_FILES)

.PHONY: check-fmt-evy fmt-evy lint-go

# --- Docs ---------------------------------------------------------------------
doc: doctest godoc toc usage

DOCTEST_CMD = ./build-tools/doctest.awk $(md) > $(O)/out.md && mv $(O)/out.md $(md)
DOCTESTS = docs/builtins.md docs/spec.md docs/syntax_by_example.md
doctest: install
	$(foreach md,$(DOCTESTS),$(DOCTEST_CMD)$(nl))

TOC_CMD = ./build-tools/toc.awk $(md) > $(O)/out.md && mv $(O)/out.md $(md)
TOCFILES = docs/builtins.md docs/spec.md
toc:
	$(foreach md,$(TOCFILES),$(TOC_CMD)$(nl))

USAGE_CMD = ./build-tools/gencmd.awk $(md) > $(O)/out.md && mv $(O)/out.md $(md)
USAGEFILES = docs/usage.md
usage: install
	$(foreach md,$(USAGEFILES),$(USAGE_CMD)$(nl))

GODOC_CMD = ./build-tools/gengodoc.awk $(filename) > $(O)/out.go && mv $(O)/out.go $(filename)
GODOCFILES = main.go
godoc: install
	$(foreach filename,$(GODOCFILES),$(GODOC_CMD)$(nl))

DOCS_TARGET_DIR = frontend/docs

## Generate static HTML documentation in frontend/docs from MarkDown in /docs
docs:
	go run ./build-tools/md docs $(DOCS_TARGET_DIR)
	npx --prefix $(NODEPREFIX) -y prettier --write $(DOCS_TARGET_DIR)

clean::
	find $(DOCS_TARGET_DIR) -mindepth 1 \
			! -regex '$(DOCS_TARGET_DIR)/css.*' \
			! -regex '$(DOCS_TARGET_DIR)/img.*' \
			! -regex '$(DOCS_TARGET_DIR)/module.*' \
			! -regex '$(DOCS_TARGET_DIR)/favicon.ico' \
			! -regex '$(DOCS_TARGET_DIR)/404.html' \
			! -regex '$(DOCS_TARGET_DIR)/index.js' \
			-delete

test-urls:
	! grep -rIioEh 'https?://[^[:space:]]+' --include "*.md" --exclude-dir "node_modules" --exclude-dir "bin" | \
		sort -u | \
		xargs -n1 curl  -sL -o /dev/null -w "%{http_code} %{url}\n"  | \
		grep -v '^200 '

.PHONY: doc docs doctest godoc sdocs test-urls toc usage

# --- frontend -----------------------------------------------------------------
NODEPREFIX = .hermit/node
NODELIB = $(NODEPREFIX)/lib

define PLAYWRIGHT_CMD_LOCAL
	npm --prefix e2e ci > /dev/null
	npx --prefix e2e playwright test --config e2e $(PLAYWRIGHT_ARGS)
endef

PLAYWRIGHT_OCI_IMAGE = mcr.microsoft.com/playwright:v1.41.1-jammy
PLAYWRIGHT_CMD_DOCKER = docker run --rm \
  --volume $$(pwd):/work/ -w /work/ \
  --network host --add-host=host.docker.internal:host-gateway \
  --env BASEURL=$(BASEURL) \
  --env NPM_CONFIG_UPDATE_NOTIFIER=false \
  $(PLAYWRIGHT_OCI_IMAGE) /bin/bash -e -c "$(subst $(nl),;,$(PLAYWRIGHT_CMD_LOCAL))"

PLAYWRIGHT_CMD = $(PLAYWRIGHT_CMD_$(if $(USE_DOCKER),DOCKER,LOCAL))

# BASEURL needs to be in the environment so that `e2e/playwright.config.js`
# can see it when the `e2e` target is called.
# The firebase-deploy script sets BASEURL to the deployment URL on GitHub CI.
SERVEDIR_HOST = $(if $(USE_DOCKER),host.docker.internal,localhost)
export SERVEDIR_PORT ?= 8080
export BASEURL ?= http://$(SERVEDIR_HOST):$(SERVEDIR_PORT)

## Serve frontend on port 8080 by default to work with e2e target
serve:
	servedir frontend

## Format code with prettier
prettier: | $(NODELIB)
	npx --prefix $(NODEPREFIX) -y prettier --write .

## Ensure code is formatted with prettier
check-prettier: | $(NODELIB)
	npx --prefix $(NODEPREFIX) -y prettier --check .

## Fix CSS files with stylelint
style: | $(NODELIB)
	npm --prefix $(NODEPREFIX) ci
	npx --prefix $(NODEPREFIX) stylelint -c $(NODEPREFIX)/.stylelintrc.json --fix frontend/**/*.css

## Lint CSS files with stylelint
check-style: | $(NODELIB)
	npm --prefix $(NODEPREFIX) ci
	npx --prefix $(NODEPREFIX) stylelint -c $(NODEPREFIX)/.stylelintrc.json frontend/**/*.css

## Install playwright on host system for `e2e` to use.
install-playwright:
	npx --prefix e2e playwright install --with-deps chromium

## Run playwright locally, or in docker if run with `make USE_DOCKER=1 ...`
run-playwright:
	@echo "running playwright against $(BASEURL)"
	$(PLAYWRIGHT_CMD)

## Run end-to-end tests with playwright (see run-playwright)
e2e: run-playwright

## Run end-to-end tests and list failed snapshot test image files.
e2e-diff: PLAYWRIGHT_ARGS = --reporter json
e2e-diff:
	$(PLAYWRIGHT_CMD) | \
	  jq -r '.suites[].suites.[]?.specs[].tests[].results[].attachments?.[].path'

## Make end-to-end testing golden screenshots with playwright (see run-playwright)
snaps: PLAYWRIGHT_ARGS = --update-snapshots
snaps: run-playwright

$(NODELIB):
	@mkdir -p $@

.PHONY: check-prettier e2e prettier serve

# --- deploy -----------------------------------------------------------------
CHANNEL = live
ENV = test

## Deploy to firebase ENV on CHANNEL. ENV: test (default), stage, prod. CHANNEL live (default), ...
deploy: build-tiny
	# Empty channel becomes to "dev" locally.
	# Empty channel becomes PR-NUM or "live" on CI.
	./build-tools/firebase-deploy $(ENV) $(CHANNEL)

.PHONY: deploy

# --- scripts ------------------------------------------------------------------
SCRIPTS = build-tools/firebase-deploy .github/scripts/app_token

## Lint script files with shellcheck and shfmt
lint-sh:
	shellcheck $(SCRIPTS)
	shfmt --diff $(SCRIPTS)

## Format script files
fmt-sh:
	shfmt --write $(SCRIPTS)

.PHONY: fmt-sh lint-sh

# --- Release -------------------------------------------------------------------
## Tag and release binaries for different OS on GitHub release
# We need to run embed first to generate the full website including evy.wasm
# for embedding in the go binary. goreleaser build hooks cannot be used as
# they run in parallel for each os/arch and cause a race condition.
release: nexttag embed
	git tag $(NEXTTAG)
	git push origin $(NEXTTAG)
	[ -z "$(CI)" ] || GITHUB_TOKEN=$$(.github/scripts/app_token) || exit 1; \
	goreleaser release --clean $(if $(RELNOTES),--release-header=$(RELNOTES))

nexttag:
	$(eval NEXTTAG := $(shell $(NEXTTAG_CMD)))
	$(eval RELNOTES := $(wildcard docs/release-notes/$(NEXTTAG).md))

.PHONY: nexttag release

define NEXTTAG_CMD
{
  { git tag --list --merged HEAD --sort=-v:refname; echo v0.0.0; }
  | grep -E "^v?[0-9]+\.[0-9]+\.[0-9]+$$"
  | head -n 1
  | awk -F . '{ print $$1 "." $$2 "." $$3 + 1 }';
  git diff --name-only @^ | sed -E -n 's|^docs/release-notes/(v[0-9]+\.[0-9]+\.[0-9]+)\.md$$|\1|p';
} | sort --reverse --version-sort | head -n 1
endef

# --- Utilities ----------------------------------------------------------------
COLOUR_NORMAL = $(shell tput sgr0 2>/dev/null)
COLOUR_RED    = $(shell tput setaf 1 2>/dev/null)
COLOUR_GREEN  = $(shell tput setaf 2 2>/dev/null)
COLOUR_WHITE  = $(shell tput setaf 7 2>/dev/null)

help:
	$(eval export HELP_AWK)
	@awk "$${HELP_AWK}" $(MAKEFILE_LIST) | sort | column -s "$$(printf \\t)" -t

$(O):
	@mkdir -p $@

.PHONY: help

# Awk script to extract and print target descriptions for `make help`.
define HELP_AWK
/^## / { desc = desc substr($$0, 3) }
/^[A-Za-z0-9%_-]+:/ && desc {
	sub(/::?$$/, "", $$1)
	printf "$(COLOUR_WHITE)%s$(COLOUR_NORMAL)\t%s\n", $$1, desc
	desc = ""
}
endef

define nl


endef
ifndef ACTIVE_HERMIT
$(eval $(subst \n,$(nl),$(shell bin/hermit env -r | sed 's/^\(.*\)$$/export \1\\n/')))
endif

# Ensure make version is gnu make 3.82 or higher
ifeq ($(filter undefine,$(value .FEATURES)),)
$(error Unsupported Make version. \
	$(nl)Use GNU Make 3.82 or higher (current: $(MAKE_VERSION)). \
	$(nl)Activate 🐚 hermit with `. bin/activate-hermit` and run again \
	$(nl)or use `bin/make`)
endif
