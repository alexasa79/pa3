APP_NAME := PA3
PRODUCT := .build/release/pa3
APP := $(APP_NAME).app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
ASSETS := Assets
BREW ?= brew
SIGN_IDENTITY ?= PA3 Local Code Signing Trusted
KEYCHAIN ?= $(HOME)/Library/Keychains/login.keychain-db
PA3_MODEL_DIR ?= $(HOME)/Library/Application Support/PA3/models
CODESIGN_CERT_DAYS ?= 3650
CODESIGN_P12_PASSWORD ?= pa3-local-codesign

.PHONY: all build native-narrator app icons speech-tools-check speech-setup tts-setup codesign-identity clean run test pa3-test reedah-test browser-test integration-test reedah-install fixtures replay-test narration-test native-stream-test decoder-test

all: app

native-narrator: Native/Narrator.mm Native/NarrationStream.h
	mkdir -p .build/native
	clang++ -std=c++17 -O2 -fobjc-arc -framework Foundation -I"$$($(BREW) --prefix llama.cpp)/include" -I"$$($(BREW) --prefix ggml)/include" Native/Narrator.mm -L"$$($(BREW) --prefix llama.cpp)/lib" -L"$$($(BREW) --prefix ggml)/lib" -Wl,-rpath,"$$($(BREW) --prefix llama.cpp)/lib" -Wl,-rpath,"$$($(BREW) --prefix ggml)/lib" -lllama -lmtmd -lggml -lggml-base -o .build/native/pa3-narrator

build: native-narrator
	swift build -c release

native-stream-test:
	mkdir -p .build/native
	clang++ -std=c++17 -O2 -I"$$($(BREW) --prefix llama.cpp)/include" -I"$$($(BREW) --prefix ggml)/include" Native/NarrationStreamTests.cpp -L"$$($(BREW) --prefix llama.cpp)/lib" -L"$$($(BREW) --prefix ggml)/lib" -Wl,-rpath,"$$($(BREW) --prefix llama.cpp)/lib" -Wl,-rpath,"$$($(BREW) --prefix ggml)/lib" -lllama -lmtmd -lggml -lggml-base -o .build/native/narration-stream-test
	.build/native/narration-stream-test

decoder-test: native-stream-test
	.build/native/narration-stream-test "$(PA3_MODEL_DIR)/qwen3-tts/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf" "$(PA3_MODEL_DIR)/qwen3-tts/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"

test: pa3-test reedah-test

pa3-test: decoder-test
	swift build
	.build/debug/pa3 --whisper-text-test
	.build/debug/pa3 --narration-recovery-test
	.build/debug/pa3 --model-download-test

reedah-test:
	$(MAKE) -C reedah test

browser-test:
	$(MAKE) -C reedah browser-test

integration-test:
	$(MAKE) -C reedah integration-test

reedah-install:
	@test -n "$(EXTENSION_ID)" || { echo 'Usage: make reedah-install EXTENSION_ID=<chrome-extension-id>'; exit 1; }
	./reedah/scripts/install_native_host.sh "$(EXTENSION_ID)"

tts-setup: speech-setup

speech-setup: speech-tools-check
	sh Tools/setup-speech.sh

narration-test:
	swift Tools/test-narration-http.swift

fixtures:
	sh Tests/make-fixtures.sh Tests/fixtures

replay-test: speech-tools-check
	swift build
	@if [ -z "$$(ls Tests/fixtures/*.wav 2>/dev/null)" ]; then $(MAKE) fixtures; fi
	PA3_INSTALL_DIR="$$(pwd)" .build/debug/pa3 --replay-test Tests/fixtures $(REPLAY_FLAGS)

icons:
	mkdir -p "$(ASSETS)"
	swift Tools/IconGenerator.swift
	iconutil -c icns "$(ASSETS)/PA3.iconset" -o "$(ASSETS)/AppIcon.icns"

speech-tools-check:
	@test -x "$$($(BREW) --prefix whisper.cpp)/bin/whisper-server" && test -x "$$($(BREW) --prefix llama.cpp)/bin/llama-tts" || { echo 'Install speech tools: brew install whisper.cpp'; exit 1; }

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

app: build icons speech-tools-check codesign-identity
	rm -rf "$(APP)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp "$(PRODUCT)" "$(MACOS)/pa3"
	cp .build/native/pa3-narrator "$(MACOS)/pa3-narrator"
	cp Info.plist "$(CONTENTS)/Info.plist"
	cp "$(ASSETS)/AppIcon.icns" "$(RESOURCES)/AppIcon.icns"
	cp "$(ASSETS)/MenuBarIcon.png" "$(RESOURCES)/MenuBarIcon.png"
	cp -R Resources/Voices "$(RESOURCES)/tts-voices"
	codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP)"

run: app
	open "$(APP)"

clean:
	rm -rf .build "$(APP)" "$(ASSETS)"
