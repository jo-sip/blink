# Contributing

Thanks for helping make Blink better!

## Getting started

```bash
git clone https://github.com/jo-sip/blink.git
cd blink
swift test                    # unit tests, a few seconds
scripts/build-app.sh --install
```

Requirements: macOS 13+, Xcode 15+ (Xcode 26+ for the Liquid Glass look; older Xcode builds use the frosted fallback).

## Before you open a pull request

- `swift test` passes.
- `scripts/smoke.sh` passes (it briefly opens the launcher window).
- New behaviour has a test. Most logic can be tested without the UI: see `Tests/BlinkTests`.
- Never commit real personal data. Tests use made-up contacts and a generated fake `chat.db`.

## Where things live

| Area | File |
| --- | --- |
| Search engine, ranking, timing | `Sources/Blink/Engine.swift` |
| Launcher window and keyboard | `Sources/Blink/Launcher.swift` |
| Built-in sources | `AppsProvider`, `BuiltinProviders`, `FilesProvider`, `MessagesProvider`, `Clipboard` |
| Plugins and Alfred workflows | `Sources/Blink/ScriptProvider.swift` |
| Settings window | `Sources/Blink/Settings.swift` |

The quickest way to add a feature is often a plugin: see "Plugins" in the README.
