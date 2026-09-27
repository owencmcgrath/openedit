CONFIGURATION ?= release

.PHONY: build exec bundle run open clean

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

clean:
	swift package clean
	rm -rf build
