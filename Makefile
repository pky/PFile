DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
XCODEBUILD   := $(DEVELOPER_DIR)/usr/bin/xcodebuild
WORKSPACE    := PFile.xcworkspace
SCHEME       := PFile
SIMULATOR    := platform=iOS Simulator,OS=latest,name=iPad mini (A17 Pro)
XCPRETTY     := $(shell which xcpretty 2>/dev/null)

export DEVELOPER_DIR

ifdef XCPRETTY
  FORMAT = set -o pipefail && $(XCODEBUILD) $1 | xcpretty
else
  FORMAT = $(XCODEBUILD) $1
endif

XCODE_FLAGS := \
	-workspace $(WORKSPACE) \
	-scheme $(SCHEME) \
	-destination '$(SIMULATOR)' \
	-configuration Debug \
	CODE_SIGN_IDENTITY="" \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO

.PHONY: all build test ci clean setup

## デフォルト: ビルド + テストを必ず両方実行
all: build test

## ビルドのみ
build:
	$(call FORMAT,$(XCODE_FLAGS) build)

## テストのみ（ビルドも含む）
test:
	$(call FORMAT,$(XCODE_FLAGS) test)

## ビルド + テストを 1コマンドで（CI向け）
ci:
	$(call FORMAT,$(XCODE_FLAGS) test)

## ビルド成果物を削除
clean:
	$(XCODEBUILD) $(XCODE_FLAGS) clean

## clone 直後の初期セットアップ
setup:
	gem install xcpretty --no-document --user-install 2>/dev/null || true
	xcodegen generate
	pod install
	sh scripts/setup-hooks.sh
