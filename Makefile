APP = build/PixelMirror.app
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $$2; exit }')

.PHONY: vendor project build install icon release publish

vendor:
	scripts/vendor.sh

project: vendor
	scripts/camera-signing.sh
	xcodegen generate

build: project
	xcodebuild -quiet -project PixelMirror.xcodeproj -scheme PixelMirror -configuration Release \
		-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
		CODE_SIGN_IDENTITY="$(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)" build
	rm -rf "$(APP)"
	ditto build/DerivedData/Build/Products/Release/PixelMirror.app "$(APP)"

install: build
	osascript -e 'quit app id "com.reffwu.pixelmirror"' || true
	rm -rf "/Applications/PixelMirror.app"
	ditto "$(APP)" "/Applications/PixelMirror.app"
	rm -rf build/DerivedData "$(APP)"
	open "/Applications/PixelMirror.app"

icon:
	test -x .venv/bin/python || (python3 -m venv .venv && .venv/bin/pip install -q pillow numpy)
	.venv/bin/python scripts/make-icon.py

release: project
	scripts/release.sh

publish: project
	scripts/release.sh --publish
