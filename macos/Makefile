APP_NAME   := Koe
BUNDLE     := build/$(APP_NAME).app
INSTALL_DIR ?= $(HOME)/Applications
# Signing (scripts/sign.sh, docs/notes/signing.md). Development builds use the
# self-signed "Koe Code Signing" certificate; ad-hoc signing (-) changes the
# cdhash every build and drops the Accessibility permission on each install.
# Release builds (dist) use the Apple Developer ID of team TEAM_ID with the
# hardened runtime and stop if it is missing (SIGN_REQUIRED=1).
#   make dist SIGN_IDENTITY="Koe Code Signing"   # a self-signed dmg for testing
SIGN_IDENTITY ?= Koe Code Signing
DIST_IDENTITY ?= Developer ID Application
TEAM_ID ?= 9RQ8WG6688
SIGN_REQUIRED ?= 0
# extra flags for swift build, e.g. SWIFT_BUILD_FLAGS="-j 4"
SWIFT_BUILD_FLAGS ?=
# 同梱する whisper-server（静的リンク・Metal 埋め込み）。無ければ同梱せず、実行時に whisperHome のものを使う
#   cmake -B build-static -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON && cmake --build build-static -j --target whisper-server
WHISPER_SERVER ?= $(HOME)/.local/src/whisper.cpp/build-static/bin/whisper-server
# バージョン番号は公開版（chaspy/koe の Release）だけに付ける。Info.plist の版は「最後に公開した版」。
# どのコードから作ったかはビルド番号（CFBundleVersion）に git のコミットを入れて区別する（メニューに出る）
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
REV := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)

build:
	swift build -c release $(SWIFT_BUILD_FLAGS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp .build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(REV)" $(BUNDLE)/Contents/Info.plist
	mkdir -p $(BUNDLE)/Contents/Resources
	cp Resources/* $(BUNDLE)/Contents/Resources/
	mkdir -p $(BUNDLE)/Contents/Resources/packs && cp ../packs/*.txt $(BUNDLE)/Contents/Resources/packs/
	if [ -x "$(WHISPER_SERVER)" ]; then cp "$(WHISPER_SERVER)" $(BUNDLE)/Contents/MacOS/whisper-server; fi
	SIGN_IDENTITY="$(SIGN_IDENTITY)" TEAM_ID=$(TEAM_ID) SIGN_REQUIRED=$(SIGN_REQUIRED) bash scripts/sign.sh $(BUNDLE)

# 録音中・文字起こし中なら終わるまで待ってから入れ替える（使いながら入れ直しても発話を失わない）
STATE := $(HOME)/Library/Application Support/Koe/state
install: build
	@for i in $$(seq 1 120); do [ "$$(cat "$(STATE)" 2>/dev/null)" = "busy" ] || break; sleep 0.5; done
	-osascript -e 'tell application id "io.github.chaspy.koe" to quit' 2>/dev/null
	@for i in $$(seq 1 40); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.5; done
	-pkill -x $(APP_NAME)
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	@sleep 1; open $(INSTALL_DIR)/$(APP_NAME).app || (sleep 2; open $(INSTALL_DIR)/$(APP_NAME).app)

# 配布用 dmg（whisper-server 同梱。モデルは初回起動時にダウンロード）
dist: SIGN_REQUIRED = 1
dist: SIGN_IDENTITY = $(DIST_IDENTITY)
dist: build
	test -f $(BUNDLE)/Contents/MacOS/whisper-server || (echo "whisper-server が同梱されていません（WHISPER_SERVER を確認）" && exit 1)
	rm -rf build/dmg && mkdir -p build/dmg
	cp -R $(BUNDLE) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "Koe $(VERSION)" -srcfolder build/dmg -ov -format UDZO build/Koe-$(VERSION).dmg
	@echo "→ build/Koe-$(VERSION).dmg"

# Developer ID dmg, notarized and stapled (notarytool profile NOTARY_PROFILE, default koe)
notarize: dist
	TEAM_ID=$(TEAM_ID) SIGN_IDENTITY="$(DIST_IDENTITY)" bash scripts/notarize.sh build/Koe-$(VERSION).dmg

# Unit tests: every Tests/<name>/main.swift, built with swiftc (no XCTest in the
# Command Line Tools). The sources a test needs are on its
# "// test-sources: A.swift B.swift" line, so adding a test needs no Makefile change.
# One test: make test T=people
T ?=
test:
	bash scripts/test.sh $(T)

clean:
	rm -rf .build build

.PHONY: build install dist notarize clean test
