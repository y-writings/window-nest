.PHONY: build test app clean

build:
	swift build

test:
	swift test

app:
	swift build -c release
	rm -rf .build/WindowNest.app
	mkdir -p .build/WindowNest.app/Contents/MacOS .build/WindowNest.app/Contents/Resources
	cp .build/release/WindowNest .build/WindowNest.app/Contents/MacOS/WindowNest
	cp Resources/Info.plist .build/WindowNest.app/Contents/Info.plist
	codesign --force --deep --sign - .build/WindowNest.app

clean:
	swift package clean
