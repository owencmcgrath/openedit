CONFIGURATION ?= release

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIGURATION)

bundle:
	./Scripts/build-app.sh $(CONFIGURATION)

run: bundle
	open -n build/OpenEdit.app

clean:
	swift package clean
	rm -rf build
