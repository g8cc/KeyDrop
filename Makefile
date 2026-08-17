.PHONY: build test app clean

build:
	swift build

test:
	swift build && ./.build/debug/KeyDropTestRunner

app:
	./make-app.sh

clean:
	rm -rf .build