# rayblob — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt run interop clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./rayblob
	rm -f rayblob
	ray build --native --release -o rayblob src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

run: build ## Serve with ./rayblob.toml (copy rayblob.example.toml first)
	./rayblob serve

interop: build ## aws-cli against a fresh rayblob: every operation, a 200 MB multipart, memory and times
	scripts/interop.sh

clean: ## Remove the binary
	rm -f rayblob
