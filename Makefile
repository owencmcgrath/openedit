CONFIGURATION ?= release
PREFIX ?= /usr/local

.PHONY: build exec bundle run open install-cli uninstall-cli clean

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
