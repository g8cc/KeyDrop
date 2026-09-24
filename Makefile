.PHONY: build test app clean

build:
	swift build

test:
	swift build && ./.build/debug/KeyDropTestRunner

app:
	./make-app.sh

# 打更新发布包:构建安装后把 .app 压成 GitHub Release 资产
# 用法: make release && gh release create vX.Y.Z dist/KeyDrop-vX.Y.Z.zip --title vX.Y.Z --notes "..."
release:
	@KEYDROP_SKIP_INSTALL=1 ./make-app.sh
	@VER=$$(sed -n 's/.*<string>\([0-9.]*\)<\/string>.*/\1/p' Info.plist | head -1); \
	mkdir -p dist; rm -f dist/KeyDrop-v$${VER}.zip; \
	ditto -c -k --keepParent "dist/KeyDrop.app" "dist/KeyDrop-v$${VER}.zip"; \
	echo "✓ dist/KeyDrop-v$${VER}.zip"; \
	echo "发布: gh release create v$${VER} dist/KeyDrop-v$${VER}.zip --title \"v$${VER}\" --notes \"更新说明\""

clean:
	rm -rf .build