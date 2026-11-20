APP = build/PixelMirror.app
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $$2; exit }')

.PHONY: vendor project build install icon release publish

vendor:
	scripts/vendor.sh

project: vendor
	scripts/camera-signing.sh
	xcodegen generate

# With the camera, Xcode signs through its own Developer ID profile, so the app
# is archived and exported the way a release is.
build: project
	rm -rf "$(APP)"
	if [ -f Config/Camera.local.xcconfig ]; then \
		xcodebuild archive -quiet -project PixelMirror.xcodeproj -scheme PixelMirror -configuration Release \
			-archivePath build/Local.xcarchive -destination 'generic/platform=macOS' \
			-clonedSourcePackagesDirPath build/SourcePackages -allowProvisioningUpdates \
			CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" && \
		xcodebuild -exportArchive -allowProvisioningUpdates -archivePath build/Local.xcarchive \
			-exportOptionsPlist Config/DeveloperID.plist -exportPath build/Local >/dev/null && \
		ditto build/Local/PixelMirror.app "$(APP)" && rm -rf build/Local build/Local.xcarchive; \
	else \
		xcodebuild -quiet -project PixelMirror.xcodeproj -scheme PixelMirror -configuration Release \
			-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
			CODE_SIGN_IDENTITY="$(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)" build && \
		ditto build/DerivedData/Build/Products/Release/PixelMirror.app "$(APP)"; \
	fi

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
