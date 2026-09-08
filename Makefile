SHELL := /bin/zsh
# /usr/local/bin is root-owned on Apple silicon Macs; Homebrew's own prefix
# (/opt/homebrew, user-writable) is the right default when Homebrew is present.
PREFIX ?= $(shell command -v brew >/dev/null 2>&1 && brew --prefix || echo /usr/local)
BUILD_DIR := $(CURDIR)/build
PRODUCT := $(CURDIR)/.build/release/say2

.PHONY: all build debug test client-test live-test smoke benchmark install uninstall clean release

all: build

build:
	swift build -c release
	mkdir -p "$(BUILD_DIR)"
	cp "$(PRODUCT)" "$(BUILD_DIR)/say2"
	codesign --force --sign - "$(BUILD_DIR)/say2"

debug:
	swift build

test:
	swift test
	$(MAKE) client-test

client-test:
	swift build --package-path Tests/Fixtures/Say2ClientConsumer

live-test: build
	SAY2_LIVE_TESTS=1 swift test --filter LiveSystemTests
	SAY2_BIN="$(BUILD_DIR)/say2" ./scripts/client-live-smoke.sh

smoke: build
	SAY2_BIN="$(BUILD_DIR)/say2" ./scripts/smoke.sh

benchmark: build
	SAY2_BIN="$(BUILD_DIR)/say2" ./scripts/benchmark.sh

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$(BUILD_DIR)/say2" "$(DESTDIR)$(PREFIX)/bin/say2"
	install -d "$(DESTDIR)$(PREFIX)/share/man/man1"
	install -m 644 man/say2.1 "$(DESTDIR)$(PREFIX)/share/man/man1/say2.1"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/say2"
	rm -f "$(DESTDIR)$(PREFIX)/share/man/man1/say2.1"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"

release:
	@if [ -z "$(VERSION)" ]; then echo "usage: make release VERSION=X.Y.Z"; exit 2; fi
	./scripts/release.sh $(VERSION)
