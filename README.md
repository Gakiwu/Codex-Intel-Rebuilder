# Codex Intel Rebuilder

[简体中文](./README_CN.md)

This project rebuilds the official `Codex.dmg` into an Intel-ready `Codex-Intel.dmg` for macOS `x86_64`.

> This repository provides scripts only. It does not include the official Codex source code, app bundle, or DMG.

## Quick Start

1. Download this repository
2. Put the official `Codex.dmg` in the project root
3. Double-click [`Codex Intel.command`](./Codex%20Intel.command)
4. Wait for the build to finish
5. Find `Codex-Intel.dmg` in the project root

## Requirements

- macOS
- Node.js and npm
- `hdiutil`, `ditto`, `codesign`, `xattr`, `/usr/libexec/PlistBuddy`
- Internet access during the build

## What It Does

`scripts/build-intel.sh` does the following:

1. Mounts the official `Codex.dmg`
2. Verifies that the bundled `Codex.app` looks like an official OpenAI release
3. Copies the app into a temporary workspace
4. Detects the Electron, Codex CLI, and native module versions from the source app
5. Builds an Intel Electron runtime workspace
6. Rebuilds `better-sqlite3` and `node-pty` for `x86_64`
7. Replaces bundled ARM binaries such as `codex` and `rg` with Intel versions
8. Signs the rebuilt app ad-hoc
9. Packages the result as `./Codex-Intel.dmg`

## Troubleshooting

If the build fails, check `log.txt`.

## Notes

- Official Codex binaries, trademarks, and related assets belong to OpenAI
- This repository is not affiliated with or endorsed by OpenAI
- Released under the MIT terms in [LICENSE](./LICENSE)
