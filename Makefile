APP_NAME := PA3
PRODUCT := .build/release/pa3
APP := $(APP_NAME).app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
ASSETS := Assets
WHISPER_DIR := whisper.cpp
WHISPER_SERVER := $(WHISPER_DIR)/build/bin/whisper-server
WHISPER_CMAKE_FLAGS ?= -DWHISPER_BUILD_TESTS=OFF -DGGML_CCACHE=OFF -DGGML_OPENMP=OFF
SIGN_IDENTITY ?= PA3 Local Code Signing Trusted

.PHONY: all build app icons whisper link-pa2-assets clean run

all: app

build:
	swift build -c release

icons:
	mkdir -p "$(ASSETS)"
	swift Tools/IconGenerator.swift
	iconutil -c icns "$(ASSETS)/PA3.iconset" -o "$(ASSETS)/AppIcon.icns"

whisper:
	git submodule update --init --recursive "$(WHISPER_DIR)"
	cmake -Wno-deprecated -S "$(WHISPER_DIR)" -B "$(WHISPER_DIR)/build" $(WHISPER_CMAKE_FLAGS)
	cmake --build "$(WHISPER_DIR)/build" --target whisper-server --config Release

app: build icons whisper link-pa2-assets
	rm -rf "$(APP)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp "$(PRODUCT)" "$(MACOS)/pa3"
	cp Info.plist "$(CONTENTS)/Info.plist"
	cp "$(ASSETS)/AppIcon.icns" "$(RESOURCES)/AppIcon.icns"
	cp "$(ASSETS)/MenuBarIcon.png" "$(RESOURCES)/MenuBarIcon.png"
	if [ -e whisper.cpp ]; then ln -s "$$(pwd)/whisper.cpp" "$(RESOURCES)/whisper.cpp"; fi
	if [ -e models ]; then ln -s "$$(pwd)/models" "$(RESOURCES)/models"; fi
	codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP)"

link-pa2-assets:
	if [ ! -e models ] && [ -e ../pa2/models ]; then ln -s ../pa2/models models; fi

run: app
	open "$(APP)"

clean:
	rm -rf .build "$(APP)" "$(ASSETS)"
