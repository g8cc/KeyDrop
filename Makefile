.PHONY: build test app clean

build:
	swift build

test:
	swift build && ./.build/debug/KeyDropTestRunner

app:
	./make-app.sh

# 打更新发布包:构建安装后把 .app 压成 GitHub Release 资产
# 用法: make release && gh release create vX.Y.Z dist/KeyDrop-vX.Y.Z.zip dist/KeyDrop-vX.Y.Z.dmg --title vX.Y.Z --notes "..."
# 资产双轨:zip 给已装用户的自动更新(更新器只认 KeyDrop-*.zip),dmg 给新用户的
# 拖动安装(包内含指向 /Applications 的链接;直接在下载目录运行会触发 App
# Translocation,自更新会静默失效 —— 拖进 Applications 是自更新的前提)
release:
	@KEYDROP_SKIP_INSTALL=1 ./make-app.sh
	@VER=$$(sed -n 's/.*<string>\([0-9.]*\)<\/string>.*/\1/p' Info.plist | head -1); \
	mkdir -p dist; rm -f dist/KeyDrop-v$${VER}.zip dist/KeyDrop-v$${VER}.dmg; \
	ditto -c -k --keepParent "dist/KeyDrop.app" "dist/KeyDrop-v$${VER}.zip"; \
	rm -rf dist/dmg-staging; mkdir -p dist/dmg-staging; \
	cp -R "dist/KeyDrop.app" dist/dmg-staging/; \
	ln -s /Applications dist/dmg-staging/Applications; \
	hdiutil create -volname "KeyDrop" -srcfolder dist/dmg-staging -ov -format UDZO "dist/KeyDrop-v$${VER}.dmg" >/dev/null; \
	rm -rf dist/dmg-staging; \
	echo "✓ dist/KeyDrop-v$${VER}.zip + dist/KeyDrop-v$${VER}.dmg"; \
	echo "发布: gh release create v$${VER} dist/KeyDrop-v$${VER}.zip dist/KeyDrop-v$${VER}.dmg --title \"v$${VER}\" --notes \"更新说明\""

clean:
	rm -rf .build