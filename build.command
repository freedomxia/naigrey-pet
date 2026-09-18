#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="奶灰.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Video actions (optional): transparent clips cut by Tools/clips/make_clips.py.
if [[ -f Assets/clips/clips.json ]]; then
  rm -rf "$APP/Contents/Resources/clips" && mkdir -p "$APP/Contents/Resources/clips"
  cp Assets/clips/clips.json Assets/clips/*.mov "$APP/Contents/Resources/clips/"
fi
if [[ ! -f "$APP/Contents/Resources/cats.png" ]]; then
  print -u2 '缺少透明素材 cats.png，请保留完整交付目录。'
  exit 1
fi
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Source/Updater.swift Source/main.swift -framework AppKit -framework ImageIO -framework QuartzCore -framework Metal -framework Accelerate -framework AVFoundation -o "$APP/Contents/MacOS/Naigrey"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Naigrey</string>
<key>CFBundleIdentifier</key><string>local.naigrey.desktop-pet</string>
<key>CFBundleName</key><string>奶灰</string>
<key>CFBundleDisplayName</key><string>奶灰桌宠</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>3.0.3</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print '构建完成：奶灰.app'
