ZIG := .toolchain/zig-aarch64-macos-0.17.0/zig

.PHONY: build test

build:
	$(ZIG) build

test:
	$(ZIG) build test
