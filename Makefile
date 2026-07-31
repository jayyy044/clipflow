APP       := dist/ClipFlow.app
BUNDLE_ID := com.jayyy044.clipflow
# A multi-arch build lands here, not in .build/release.
UNIVERSAL := .build/apple/Products/Release

# macOS keys the Accessibility grant on bundle id + signing identity. With an
# ad-hoc signature there is no identity, so the binary's own hash serves as one
# and every rebuild looks like an app that has never been granted anything —
# meaning the grant has to be re-issued after each build (DECISIONS S-13).
#
# Discovered rather than hardcoded, so a machine without a Development
# certificate still builds; it just falls back to ad-hoc and re-prompts.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
SIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

.PHONY: all bundle run install uninstall debug clean

all: bundle

## Assemble a real .app so the process survives the terminal that started it,
## and so it has a stable bundle identity for the Accessibility grant in Phase 4.
bundle:
	# Both architectures, because NFR-2 asks for a universal binary and SPM builds
	# only for the host unless told otherwise — it was silently arm64-only until
	# someone actually ran `lipo -archs` on it. Costs a second compile; `make
	# debug` stays host-only for iterating.
	swift build -c release --arch arm64 --arch x86_64
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(UNIVERSAL)/ClipFlow $(APP)/Contents/MacOS/ClipFlow
	# The OCR helper lives beside the main binary because that is how the app
	# finds it — relative to its own executable, never by absolute path
	# (DECISIONS D-9).
	cp $(UNIVERSAL)/ClipFlowOCR $(APP)/Contents/MacOS/ClipFlowOCR
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	@echo "signing as: $(SIGN_ID)"
	# Nested code first: the bundle signature seals whatever is inside it, so
	# signing the app before the helper invalidates the app's own signature the
	# moment the helper is signed.
	codesign --force --sign "$(SIGN_ID)" $(APP)/Contents/MacOS/ClipFlowOCR
	codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) $(APP)

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
