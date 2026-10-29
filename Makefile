all: app

# 生成 build/MiniShot.app
app:
	./build-app.sh

# 运行单元测试（长截图对齐与拼接）
test:
	swift test

# 复制到“应用程序”并打开
install: app
	-osascript -e 'quit app "MiniShot"'
	rm -rf /Applications/MiniShot.app
	cp -R build/MiniShot.app /Applications/
	open /Applications/MiniShot.app

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf build .build

.PHONY: all app test install icon clean
