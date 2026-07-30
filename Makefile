APP       := dist/ClipFlow.app
BUNDLE_ID := com.jayyy044.clipflow

.PHONY: all bundle run install uninstall debug clean

all: bundle

## Assemble a real .app so the process survives the terminal that started it,
## and so it has a stable bundle identity for the Accessibility grant in Phase 4.
bundle:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/ClipFlow $(APP)/Contents/MacOS/ClipFlow
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	# ponytail: ad-hoc signature. Good enough to launch, but the hash changes
	# every build, so macOS revokes the Accessibility grant each time. Swap the
	# `-` for a real "Apple Development" identity before Phase 4 (DECISIONS S-13).
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)

run: bundle
	-pkill -x ClipFlow
	open $(APP)

install: bundle
	-pkill -x ClipFlow
	rm -rf /Applications/ClipFlow.app
	cp -R $(APP) /Applications/ClipFlow.app
	open /Applications/ClipFlow.app

uninstall:
	-pkill -x ClipFlow
	rm -rf /Applications/ClipFlow.app

## Unbundled binary, for iterating. Note it reads a DIFFERENT UserDefaults
## domain than the bundle (`ClipFlow` vs `com.jayyy044.clipflow`), so the hotkey
## preference does not carry across.
debug:
	swift build
	-pkill -x ClipFlow
	./.build/debug/ClipFlow

clean:
	rm -rf .build dist
