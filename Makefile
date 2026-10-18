.PHONY: build test app clean

CODE_SIGN_IDENTITY ?= -

build:
	swift build

test:
	swift test

app:
ifeq ($(CODE_SIGN_IDENTITY),-)
	@printf '%s\n' \
		'Warning: ad-hoc signing can invalidate macOS permissions after code changes.' \
		'Set CODE_SIGN_IDENTITY to a signing certificate to keep the app identity stable. See README.md for recovery steps.'
endif
	swift build -c release
	rm -rf .build/WindowNest.app
	mkdir -p .build/WindowNest.app/Contents/MacOS .build/WindowNest.app/Contents/Resources
	cp .build/release/WindowNest .build/WindowNest.app/Contents/MacOS/WindowNest
	cp Resources/Info.plist .build/WindowNest.app/Contents/Info.plist
	codesign --force --deep --sign "$(CODE_SIGN_IDENTITY)" .build/WindowNest.app

clean:
	swift package clean
