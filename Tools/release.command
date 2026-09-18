#!/bin/zsh
# 发布一个新版本：改版本号 → 编译 → 跑测试 → 打包 → 签名 → 传 GitHub Release → 更新 updates/latest.json
#
#   Tools/release.command 3.0.3 "这次改了什么"
#
# 私钥默认在 ~/.naigrey/release-key（不在仓库里）。没有的话先生成：
#   xcrun swiftc -O Tools/relkey/main.swift -o /tmp/relkey && /tmp/relkey keygen ~/.naigrey/release-key
# 生成时打印出来的公钥要填进 Source/Updater.swift 的 publicKey。
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:-}
NOTES=${2:-"例行更新"}
KEY=${NAIGREY_KEY:-$HOME/.naigrey/release-key}
ASSET="naigrey-mac.zip"

if [[ -z "$VERSION" ]]; then print -u2 "用法：Tools/release.command <版本号> [更新说明]"; exit 1; fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then print -u2 "版本号要像 3.0.3"; exit 1; fi
if [[ ! -f "$KEY" ]]; then print -u2 "找不到签名私钥：$KEY"; exit 1; fi

OWNER=$(grep -o 'static let owner = "[^"]*"' Source/Updater.swift | sed 's/.*"\(.*\)"/\1/')
REPO=$(grep -o 'static let repo = "[^"]*"' Source/Updater.swift | sed 's/.*"\(.*\)"/\1/')
OLD_BUILD=$(grep -o '<key>CFBundleVersion</key><string>[0-9]*' build.command | grep -o '[0-9]*$')
BUILD=$((OLD_BUILD + 1))
print "发布 $VERSION（build $BUILD）到 $OWNER/$REPO"

# 版本号写进构建脚本，构建号只增不减（更新判断只看它）
sed -i '' "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VERSION</string>|" build.command
sed -i '' "s|<key>CFBundleVersion</key><string>[^<]*</string>|<key>CFBundleVersion</key><string>$BUILD</string>|" build.command

./build.command
./Tests/verify.command > /dev/null
print "测试通过"

mkdir -p dist
rm -f "dist/$ASSET"
ditto -c -k --sequesterRsrc --keepParent 奶灰.app "dist/$ASSET"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -O Tools/relkey/main.swift -o "$WORK/relkey" 2>/dev/null
SHA=$(shasum -a 256 "dist/$ASSET" | cut -d' ' -f1)
SIG=$("$WORK/relkey" sign "$KEY" "dist/$ASSET")
"$WORK/relkey" verify "$("$WORK/relkey" pub "$KEY")" "$SIG" "dist/$ASSET" > /dev/null
SIZE=$(stat -f%z "dist/$ASSET")
print "包 $(( SIZE / 1048576 ))MB，已签名"

# 先发 Release，再让 feed 指过去，避免更新信息指向还不存在的文件
if gh release view "v$VERSION" --repo "$OWNER/$REPO" > /dev/null 2>&1; then
  gh release upload "v$VERSION" "dist/$ASSET" --repo "$OWNER/$REPO" --clobber
else
  gh release create "v$VERSION" "dist/$ASSET" --repo "$OWNER/$REPO" --title "奶灰桌宠 $VERSION" --notes "$NOTES"
fi

mkdir -p updates
cat > updates/latest.json <<JSON
{
  "mac": {
    "version": "$VERSION",
    "build": $BUILD,
    "url": "https://github.com/$OWNER/$REPO/releases/download/v$VERSION/$ASSET",
    "sha256": "$SHA",
    "signature": "$SIG",
    "minimumSystem": "13.0",
    "notes": "$NOTES",
    "date": "$(date +%Y-%m-%d)"
  },
  "windows": null
}
JSON

git add -A
git commit -m "发布 $VERSION（build $BUILD）：$NOTES" > /dev/null
git push

print "发布完成：https://github.com/$OWNER/$REPO/releases/tag/v$VERSION"
print "更新源：https://raw.githubusercontent.com/$OWNER/$REPO/main/updates/latest.json"
