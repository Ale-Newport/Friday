# Friday — developer entry points. Thin wrappers over swift / uv / xcodegen / xcodebuild.
SHELL := /bin/bash
DERIVED = build/DerivedData

.PHONY: help bootstrap project test test-sidecar app run release install package-sidecar clean

help:
	@echo "make bootstrap       fetch the speech library + models (checksum-verified), set up the Python sidecar, generate Friday.xcodeproj"
	@echo "make test            Swift package tests (no microphone, key or network needed)"
	@echo "make test-sidecar    Python sidecar unit tests"
	@echo "make app             build Friday.app (Debug)"
	@echo "make run             build and launch Friday.app (Debug; uses Sidecar/.venv for the browser agent)"
	@echo "make release         build a Release Friday.app (embeds the packaged sidecar when Sidecar/dist exists)"
	@echo "make package-sidecar package the Python sidecar with PyInstaller for the Release app"
	@echo "make install         copy the Release app to /Applications"

bootstrap:
	Scripts/fetch-sherpa.sh
	Scripts/fetch-speech-models.sh
	cd Sidecar && uv sync
	$(MAKE) project

project:
	xcodegen generate

test:
	swift test

test-sidecar:
	cd Sidecar && uv run pytest tests --ignore=tests/integration -q

app: project
	set -o pipefail; xcodebuild -project Friday.xcodeproj -scheme Friday -configuration Debug -derivedDataPath $(DERIVED) build | tail -5

run: app
	open $(DERIVED)/Build/Products/Debug/Friday.app

release: project
	set -o pipefail; xcodebuild -project Friday.xcodeproj -scheme Friday -configuration Release -derivedDataPath $(DERIVED) build | tail -5

package-sidecar:
	Scripts/package-sidecar.sh

install: release
	ditto $(DERIVED)/Build/Products/Release/Friday.app /Applications/Friday.app
	@echo "Installed. Open Friday from /Applications; enable Open at Login in Settings ▸ General."

clean:
	rm -rf .build build Friday.xcodeproj
