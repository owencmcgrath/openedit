CONFIGURATION ?= release

.PHONY: build run bundle open clean

build:
	swift build -c $(CONFIGURATION)

# Local dev run (bare executable, no bundle). Optional: make run FILE=/path/to/file
run:
	swift run -c $(CONFIGURATION) OpenEdit $(FILE)

bundle:
	./Scripts/build-app.sh $(CONFIGURATION)

# Launch the bundled .app. Needed for application(_:open:)/single-instance reuse.
# Optional: make open FILE=/path/to/file
open: bundle
	open -n build/OpenEdit.app --args $(FILE)

clean:
	swift package clean
	rm -rf build
