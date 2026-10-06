DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/glasstap.app

.PHONY: project build test run

project:
	xcodegen generate

build: project
	xcodebuild -project glasstap.xcodeproj -scheme glasstap -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build

test:
	cd GlasstapKit && swift test

run:
	open $(APP)
