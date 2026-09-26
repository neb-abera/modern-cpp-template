.PHONY: install coverage test asan bench proof verify verify-docker shell docs format prose lint help
.DEFAULT_GOAL := help

define BROWSER_PYSCRIPT
import os, webbrowser, sys

try:
	from urllib import pathname2url
except:
	from urllib.request import pathname2url

webbrowser.open("file://" + pathname2url(os.path.abspath(sys.argv[1])))
endef
export BROWSER_PYSCRIPT

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-20s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

BROWSER := python3 -c "$$BROWSER_PYSCRIPT"
INSTALL_LOCATION := ~/.local
# Docker image/container names derive from the checkout directory, so
# projects generated from this template need no edits here.
IMAGE := $(shell basename "$(CURDIR)" | tr '[:upper:]' '[:lower:]')
# The shell mounts the tree read-write, so it runs as the host user: a file
# it writes (build/, a reformatted source) belongs to whoever owns the
# checkout, and a merged worktree can be removed without sudo. HOME points
# somewhere that user can write, since the image's home belongs to uid 1000.
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)
export HOST_UID HOST_GID

help:
	@python3 -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

test: ## build and run tests with ctest
	cmake --preset release
	cmake --build --preset release
	ctest --preset release

proof: ## prove the CBMC harnesses in proof/ for every input of the type
	./scripts/check-proofs.sh

coverage: ## check code coverage with GCC/Clang
	cmake --preset coverage
	cmake --build --preset coverage
	ctest --preset coverage
	find build/coverage -type f -name '*.gcno' -exec gcov -pb {} +

bench: ## build and run the Google Benchmark targets
	cmake --preset bench
	cmake --build --preset bench
	./build/bench/bench/tmp_bench

verify: ## run the full verification suite with a pass/fail tally
	./scripts/verify.sh

verify-docker: ## run the full verification suite inside the Docker toolchain image
	./scripts/verify-docker.sh

shell: ## open a development shell inside the Docker toolchain image
	docker build -t $(IMAGE):latest .
	docker rm -f $(IMAGE)-dev 2>/dev/null || true
	docker run --rm -it --name $(IMAGE)-dev --user $(HOST_UID):$(HOST_GID) -e HOME=/tmp/home \
		-v $(CURDIR):/work -w /work $(IMAGE):latest bash

asan: ## build and run tests under Address/UB sanitizers
	cmake --preset asan
	cmake --build --preset asan
	ctest --preset asan

docs: ## generate Doxygen HTML documentation, including API docs
	rm -rf docs/
	cmake --preset release -DProject_ENABLE_DOXYGEN=1
	cmake --build --preset release --target doxygen-docs
	$(BROWSER) docs/html/index.html

install: ## install the package to the `INSTALL_LOCATION`
	cmake --preset release
	cmake --build --preset release
	cmake --install build/release --prefix $(INSTALL_LOCATION)

format: ## format the project sources
	cmake --preset release
	cmake --build --preset release --target clang-format

lint: ## actionlint and shellcheck from the Dockerfile's lint stage, self-test first
	./scripts/lint.sh --self-test
	./scripts/lint.sh

prose: ## lint every tracked Markdown file against the writing rules (.vale/styles/Abera)
	./scripts/check-prose.sh --self-test
	./scripts/check-prose.sh
