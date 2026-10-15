APP_NAME   := Koe
BUNDLE     := build/$(APP_NAME).app
INSTALL_DIR ?= $(HOME)/Applications
# 署名 identity を固定すると、再ビルドしてもマイク・アクセシビリティの許可が外れない
SIGN_IDENTITY ?= -
# 同梱する whisper-server（静的リンク・Metal 埋め込み）。無ければ同梱せず、実行時に whisperHome のものを使う
#   cmake -B build-static -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON && cmake --build build-static -j --target whisper-server
WHISPER_SERVER ?= $(HOME)/.local/src/whisper.cpp/build-static/bin/whisper-server
# バージョン番号は公開版（chaspy/koe の Release）だけに付ける。Info.plist の版は「最後に公開した版」。
# どのコードから作ったかはビルド番号（CFBundleVersion）に git のコミットを入れて区別する（メニューに出る）
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
REV := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)

build:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp .build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(REV)" $(BUNDLE)/Contents/Info.plist
	mkdir -p $(BUNDLE)/Contents/Resources
	cp Resources/* $(BUNDLE)/Contents/Resources/
	mkdir -p $(BUNDLE)/Contents/Resources/packs && cp ../packs/*.txt $(BUNDLE)/Contents/Resources/packs/
	if [ -x "$(WHISPER_SERVER)" ]; then cp "$(WHISPER_SERVER)" $(BUNDLE)/Contents/MacOS/whisper-server; fi
	if [ -f $(BUNDLE)/Contents/MacOS/whisper-server ]; then codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE)/Contents/MacOS/whisper-server; fi
	codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE)

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
dist: build
	test -f $(BUNDLE)/Contents/MacOS/whisper-server || (echo "whisper-server が同梱されていません（WHISPER_SERVER を確認）" && exit 1)
	rm -rf build/dmg && mkdir -p build/dmg
	cp -R $(BUNDLE) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "Koe $(VERSION)" -srcfolder build/dmg -ov -format UDZO build/Koe-$(VERSION).dmg
	@echo "→ build/Koe-$(VERSION).dmg"

# 文字列処理の単体テスト（XCTest は Command Line Tools に無いので swiftc で直接ビルドする）
test:
	mkdir -p build
	swiftc -O -o build/text-test Sources/Koe/Repeats.swift Tests/text/main.swift
	./build/text-test

clean:
	rm -rf .build build

.PHONY: build install dist clean test
