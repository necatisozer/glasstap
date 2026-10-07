DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/glasstap.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/glasstap.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: project build test run install

project:
	scripts/xcodegen.sh generate

build: project
	xcodebuild -project glasstap.xcodeproj -scheme glasstap -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build

test:
	cd GlasstapKit && swift test

run:
	open $(APP)

# Builds a Release app signed with your team, copies it to $(INSTALL_DIR) and opens it. The app takes
# that team for WebDriverAgent. The team goes into Config/Local.xcconfig, so make build uses it too.
# TEAM=ABCDE12345 chooses one of several teams.
install: project
	@if [ -n "$(TEAM)" ] || [ ! -f Config/Local.xcconfig ]; then \
		team="$(TEAM)"; [ -n "$$team" ] || team=$$(scripts/find-team.sh) || exit 1; \
		touch Config/Local.xcconfig; sed -i '' '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/d' Config/Local.xcconfig; \
		echo "DEVELOPMENT_TEAM = $$team" >> Config/Local.xcconfig; fi
	xcodebuild -project glasstap.xcodeproj -scheme glasstap -configuration Release -derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" -quiet build
	@# A running glasstap stops its WDA runs before it quits, which can take 10 s. Until it is gone, open would show it again.
	@if pgrep -xq glasstap; then osascript -e 'quit app "glasstap"'; \
		for i in $$(seq 15); do pgrep -xq glasstap || break; sleep 1; done; fi
	@mkdir -p "$(INSTALL_DIR)" && rm -rf "$(INSTALL_DIR)/glasstap.app" && ditto $(RELEASE_APP) "$(INSTALL_DIR)/glasstap.app"
	@echo "Installed $(INSTALL_DIR)/glasstap.app"
	open "$(INSTALL_DIR)/glasstap.app"
