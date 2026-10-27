ZIG_VERSION := 0.17.0
ZIG_TARGET := aarch64-macos
ZIG_NAME := zig-$(ZIG_TARGET)-$(ZIG_VERSION)
ZIG_SHA256 := b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
ZIG := .toolchain/$(ZIG_NAME)/zig
GHOSTTY := vendor/ghostty/build.zig

.PHONY: build test toolchain

build: $(ZIG) $(GHOSTTY)
	cargo build

test: $(ZIG) $(GHOSTTY)
	cargo test

toolchain: $(ZIG)

$(ZIG):
	rm -rf .toolchain/download
	mkdir -p .toolchain/download
	curl -fL -o .toolchain/download/$(ZIG_NAME).tar.xz https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_NAME).tar.xz
	echo "$(ZIG_SHA256)  .toolchain/download/$(ZIG_NAME).tar.xz" | shasum -a 256 -c
	tar -xJf .toolchain/download/$(ZIG_NAME).tar.xz -C .toolchain/download
	rm -rf .toolchain/$(ZIG_NAME)
	mv .toolchain/download/$(ZIG_NAME) .toolchain/$(ZIG_NAME)
	rm -rf .toolchain/download

$(GHOSTTY):
	git submodule update --init vendor/ghostty
