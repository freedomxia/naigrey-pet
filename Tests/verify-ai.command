#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-ai-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
CN_OBJECT=$(mktemp "${TMPDIR:-/tmp/}naigrey-zstd.XXXXXX")
trap 'rm -rf "$TEST_DIR"; rm -f "$CN_OBJECT"' EXIT
xcrun clang -O2 -target arm64-apple-macos13.0 -c Source/Vendor/zstd/zstddeclib.c -o "$CN_OBJECT"
xcrun swiftc -import-objc-header Source/Vendor/zstd/CodenotchZstd.h "$CN_OBJECT" -parse-as-library -target arm64-apple-macos13.0 Source/AICompanion/*.swift Tests/AICompanion/*.swift -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications -o "$TEST_DIR/verify-ai"
"$TEST_DIR/verify-ai"
