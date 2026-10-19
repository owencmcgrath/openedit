CONFIGURATION ?= release
PREFIX ?= /usr/local

# Tests use Swift Testing; XCTest is not shipped with Command Line Tools, so
# `--disable-xctest` keeps SwiftPM from linking a framework this toolchain
# lacks. The test bundle is ad-hoc signed, and a checkout under a File
# Provider-managed folder (e.g. iCloud-backed ~/Documents) attaches detritus
# xattrs that codesign refuses, so tests build outside the checkout. Override
# with SCRATCH=/some/path.
SCRATCH ?= $(or $(TMPDIR),/tmp/)openedit-tests

# The Command Line Tools toolchain does not auto-discover Swift Testing's macro
# plugin (Xcode does), so point swiftc at it explicitly when it is present and
# the active toolchain is the CLT one.
CLT_PLUGIN := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
ifeq ($(shell xcode-select -p),/Library/Developer/CommandLineTools)
TESTING_PLUGIN_FLAGS := $(if $(wildcard $(CLT_PLUGIN)),-Xswiftc -load-plugin-library -Xswiftc $(CLT_PLUGIN))
endif

.PHONY: build exec bundle run open test test-cli install-cli uninstall-cli clean

build:
	swift build -c $(CONFIGURATION)

# Bare executable via `swift run`. Fast, but macOS won't let a shell-exec'd
# process become the active app, so the window renders inactive (dull traffic
# lights) and application(_:open:)/single-instance behavior is unavailable.
# Optional: make exec FILE=/path/to/file
exec:
	swift run -c $(CONFIGURATION) OpenEdit $(FILE)

bundle:
	./Scripts/build-app.sh $(CONFIGURATION)

test: test-cli
	swift test --scratch-path "$(SCRATCH)" --enable-swift-testing --disable-xctest $(TESTING_PLUGIN_FLAGS)

# Flag parsing and forwarding of the CLI shim (ARCHITECTURE.md 5.1); plain
# bash, no app or window server needed.
test-cli:
	./Scripts/tests/openedit-cli-tests.sh

# Normal way to run the app: bundle it, then launch through LaunchServices so
# it activates and gets standard window chrome.
# Optional: make run FILE=/path/to/file
run: bundle
	open -n build/OpenEdit.app --args $(FILE)

open:
	open -n build/OpenEdit.app --args $(FILE)

# Installs the CLI shim only; the app bundle itself lives wherever it was
# bundled (the shim looks in /Applications, ~/Applications, and a dev
# checkout's build/, or accepts an OPENEDIT_APP override). /usr/local/bin
# usually needs sudo: `sudo make install-cli`, or
# `make install-cli PREFIX=$$HOME/.local`.
install-cli:
	install -d "$(PREFIX)/bin"
	install -m 0755 Scripts/openedit "$(PREFIX)/bin/openedit"

uninstall-cli:
	rm -f "$(PREFIX)/bin/openedit"

clean:
	swift package clean
	rm -rf build
