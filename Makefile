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
KEYCHAIN ?= $(HOME)/Library/Keychains/login.keychain-db
CODESIGN_CERT_DAYS ?= 3650
CODESIGN_P12_PASSWORD ?= pa3-local-codesign

.PHONY: all build app icons whisper link-pa2-assets codesign-identity clean run test fixtures replay-test

all: app

build:
	swift build -c release

test:
	swift build
	.build/debug/pa3 --whisper-text-test

fixtures:
	sh Tests/make-fixtures.sh Tests/fixtures

replay-test: whisper
	swift build
	@if [ -z "$$(ls Tests/fixtures/*.wav 2>/dev/null)" ]; then $(MAKE) fixtures; fi
	PA3_INSTALL_DIR="$$(pwd)" .build/debug/pa3 --replay-test Tests/fixtures $(REPLAY_FLAGS)

icons:
	mkdir -p "$(ASSETS)"
	swift Tools/IconGenerator.swift
	iconutil -c icns "$(ASSETS)/PA3.iconset" -o "$(ASSETS)/AppIcon.icns"

whisper:
	git submodule update --init --recursive "$(WHISPER_DIR)"
	cmake -Wno-deprecated -S "$(WHISPER_DIR)" -B "$(WHISPER_DIR)/build" $(WHISPER_CMAKE_FLAGS)
	cmake --build "$(WHISPER_DIR)/build" --target whisper-server --config Release

codesign-identity:
	@set -e; \
	if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "Using ad-hoc code signing identity."; \
	elif security find-identity -v -p codesigning | grep -Fq '"$(SIGN_IDENTITY)"'; then \
		echo "Code signing identity exists: $(SIGN_IDENTITY)"; \
	else \
		echo "Creating local code signing identity: $(SIGN_IDENTITY)"; \
		tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/pa3-codesign.XXXXXX"); \
		trap 'rm -rf "$$tmpdir"' EXIT; \
		printf '%s\n' \
			'[req]' \
			'distinguished_name = req_distinguished_name' \
			'x509_extensions = v3_codesign' \
			'prompt = no' \
			'' \
			'[req_distinguished_name]' \
			'CN = $(SIGN_IDENTITY)' \
			'' \
			'[v3_codesign]' \
			'basicConstraints = critical,CA:FALSE' \
			'keyUsage = critical,digitalSignature' \
			'extendedKeyUsage = critical,codeSigning' \
			> "$$tmpdir/cert.conf"; \
		openssl req -newkey rsa:2048 -nodes -keyout "$$tmpdir/key.pem" -x509 -days "$(CODESIGN_CERT_DAYS)" -out "$$tmpdir/cert.pem" -config "$$tmpdir/cert.conf"; \
		openssl pkcs12 -export -inkey "$$tmpdir/key.pem" -in "$$tmpdir/cert.pem" -out "$$tmpdir/cert.p12" -name "$(SIGN_IDENTITY)" -passout pass:"$(CODESIGN_P12_PASSWORD)"; \
		security import "$$tmpdir/cert.p12" -k "$(KEYCHAIN)" -P "$(CODESIGN_P12_PASSWORD)" -T /usr/bin/codesign; \
		security add-trusted-cert -d -r trustRoot -p codeSign -k "$(KEYCHAIN)" "$$tmpdir/cert.pem"; \
	fi

app: build icons whisper link-pa2-assets codesign-identity
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
