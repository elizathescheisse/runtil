WATCH_ID ?= 9D1899D9-438B-4FD4-AE56-C8997CE55D01
PHONE_ID ?= 7A4711B4-B2D5-46B1-9AF4-5B0016BAF32D
WATCH_BUNDLE = com.ergilp.runtil.watchkitapp
PLAN ?= Zone 2
PAGE ?= metrics
# Simulated seconds per real second. 10 runs a whole plan quickly; 1 is the speed to use
# when you need to watch what the screen does in the seconds after a cue.
SPEED ?= 10

.PHONY: project test build build-watch run-watch run-phone shot clean

## Regenerate Runtil.xcodeproj from project.yml
project: Local.xcconfig
	xcodegen generate

# Signing config is per-machine and gitignored, so a fresh clone needs one before
# XcodeGen can resolve it.
Local.xcconfig:
	cp Local.xcconfig.example $@
	@echo "Created Local.xcconfig — set DEVELOPMENT_TEAM in it before building to a device."

## Engine tests — pure Swift, no device, sub-second
test:
	swift test --package-path RuntilCore

## Build the iOS app (embeds the watch app)
build: project
	xcodebuild -project Runtil.xcodeproj -scheme Runtil \
		-destination 'platform=iOS Simulator,id=$(PHONE_ID)' \
		-derivedDataPath .build build CODE_SIGNING_ALLOWED=NO | tail -1

build-watch: project
	xcodebuild -project Runtil.xcodeproj -scheme RuntilWatch \
		-destination 'platform=watchOS Simulator,id=$(WATCH_ID)' \
		-derivedDataPath .build build CODE_SIGNING_ALLOWED=NO | tail -1

## Start a simulated run on the watch. PLAN="1:30" PAGE=log SPEED=1 make run-watch
run-watch: build-watch
	-xcrun simctl boot $(WATCH_ID)
	-xcrun simctl terminate $(WATCH_ID) $(WATCH_BUNDLE)
	xcrun simctl install $(WATCH_ID) .build/Build/Products/Debug-watchsimulator/runtil.app
	xcrun simctl launch $(WATCH_ID) $(WATCH_BUNDLE) -autostart "$(PLAN)" -page $(PAGE) -speed $(SPEED)

run-phone: build
	-xcrun simctl boot $(PHONE_ID)
	xcrun simctl install $(PHONE_ID) .build/Build/Products/Debug-iphonesimulator/runtil.app
	xcrun simctl launch $(PHONE_ID) com.ergilp.runtil

shot:
	xcrun simctl io $(WATCH_ID) screenshot --type=png watch.png

clean:
	rm -rf .build Runtil.xcodeproj
