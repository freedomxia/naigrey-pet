# Third-party notices

## Codenotch

Source reference: [Codenotch v1.14.0](https://github.com/vinzdg/codenotch/tree/v1.14.0), commit `c5b40a00c9c7df99acaeac0e6c9af49a452f4dda`.

`Source/AICompanion/Providers.swift` adapts protocol field mappings, endpoint/header constants, default Keychain service naming and read-only credential handling from:

- `Sources/Providers/CodexCredentials.swift`
- `Sources/Providers/CodexLocalProvider.swift`
- `Sources/Providers/CodexUsage.swift`
- `Sources/Providers/ClaudeCredentials.swift`
- `Sources/Providers/ClaudeOAuthProvider.swift`
- `Sources/Providers/ClaudeProfile.swift`

The quota core now reuses the following v1.14.0 modules in `Source/AICompanion/CN*.swift`:

- `ThresholdNotifier` (decision core; host delivers alerts), `UsageResetWatcher`, `UsageLimitWatcher`
- `ResetCopy`, `CodexUsage`, `UsageResponse` extracted from `ClaudeOAuthProvider`
- `ClaudeUsageCLI`, `ClaudeDesktopUsageCache`, `ClaudeCLI`, `ClaudeTokenRefresher`

Host adaptations: narrow AppKit model/localization bridges, Naigrey's own CLI scratch directory, import Combine for the renewal class, and provider lifecycle/connection controls. `ClaudeQuotaSources.swift` adapts the default-profile source ordering, 30-minute Desktop freshness, 5-minute CLI/miss caching, expired-window checks, OAuth retry and exponential backoff from `ClaudeOAuthProvider`. No Codenotch UI, updater, or Phone Link is included. The two-provider UI connects the default Codex and Claude profiles; it does not expose Codenotch's multi-profile discovery UI.

`Tests/AICompanion/CacheRenewalTests.swift` contains a compressed synthetic fixture from upstream `ClaudeDesktopUsageCacheTests.swift` (same MIT license).

`Source/Vendor/zstd/` contains the upstream decode-only Zstandard v1.5.7 amalgamation, licensed under BSD-3-Clause. Its license and provenance are included alongside the source. It is compiled statically; no Homebrew library is required at runtime.

### MIT License

Copyright (c) 2026 Vinz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
