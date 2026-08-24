.PHONY: install coverage test asan verify verify-docker shell docs format help
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

help:
	@python3 -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

test: ## build and run tests with ctest
	cmake --preset release
	cmake --build --preset release
	ctest --preset release

coverage: ## check code coverage with GCC/Clang
	cmake --preset coverage
	cmake --build --preset coverage
	ctest --preset coverage
	find build/coverage -type f -name '*.gcno' -exec gcov -pb {} +

verify: ## run the full verification suite with a pass/fail tally
	./scripts/verify.sh

verify-docker: ## run the full verification suite inside the Docker toolchain image
	./scripts/verify-docker.sh

shell: ## open a development shell inside the Docker toolchain image
	docker build -t modern-cpp-template:latest .
	docker rm -f mct-dev 2>/dev/null || true
	docker run --rm -it --name mct-dev -v $(CURDIR):/work -w /work modern-cpp-template:latest bash

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
