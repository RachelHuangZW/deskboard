#!/bin/zsh
# 编译 DeskBoard.app 并安装到 ~/Applications，然后启动
set -e
cd "$(dirname "$0")"

APP="build/DeskBoard.app"
DEST="$HOME/Applications/DeskBoard.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/DeskBoard" main.swift -framework Cocoa -framework WebKit
cp Info.plist "$APP/Contents/"
cp index.html "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

pkill -x DeskBoard 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "已安装并启动：$DEST"
