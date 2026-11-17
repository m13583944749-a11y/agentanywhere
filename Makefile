SHELL := /bin/bash

BUNDLE_ID ?= app.galnook.ios
export BUNDLE_ID

.DEFAULT_GOAL := help
.PHONY: help generate test build ci clean distclean

help:
	@printf '%s\n' \
	  'make generate   使用 XcodeGen 生成 GalNook.xcodeproj' \
	  'make test       在 iOS 模拟器运行单元测试' \
	  'make build      构建未签名 xcarchive 和 IPA' \
	  'make ci         依次运行测试和构建' \
	  'make clean      删除 .build 构建产物' \
	  'make distclean  同时删除生成的 Xcode 工程' \
	  '' \
	  '可覆盖变量：BUNDLE_ID、SIMULATOR_NAME、SIMULATOR_OS、DESTINATION' \
	  '示例：make test BUNDLE_ID=com.example.galnook SIMULATOR_NAME="iPhone 16 Pro"'

generate:
	@bash scripts/generate.sh

test:
	@bash scripts/test.sh

build:
	@bash scripts/build.sh

ci: test build

clean:
	@rm -rf .build

distclean: clean
	@rm -rf GalNook.xcodeproj
