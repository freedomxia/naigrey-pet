#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-ai-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 Source/AICompanion/*.swift Tests/AICompanion/*.swift -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications -o "$TEST_DIR/verify-ai"
"$TEST_DIR/verify-ai"
