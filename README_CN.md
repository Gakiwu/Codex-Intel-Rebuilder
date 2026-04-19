# Codex Intel Rebuilder

[English](./README.md)

这个项目会把官方 `Codex.dmg` 重新构建为适用于 macOS Intel `x86_64` 的 `Codex-Intel.dmg`。

> 本仓库只提供脚本，不包含官方 Codex 源码、应用本体或 DMG。

## 快速开始

1. 下载本项目到本地
2. 把官方 `Codex.dmg` 放到项目根目录
3. 双击 [`Codex Intel.command`](./Codex%20Intel.command)
4. 等待构建完成
5. 在项目根目录找到 `Codex-Intel.dmg`

## 依赖

- macOS
- Node.js 和 npm
- `hdiutil`、`ditto`、`codesign`、`xattr`、`/usr/libexec/PlistBuddy`
- 构建时需要联网

## 脚本会做什么

`scripts/build-intel.sh` 会执行这些步骤：

1. 挂载官方 `Codex.dmg`
2. 校验里面的 `Codex.app` 看起来是否为官方 OpenAI 发布
3. 复制应用到临时工作目录
4. 从源应用中识别 Electron、Codex CLI 和原生模块版本
5. 构建 Intel Electron 运行时工作目录
6. 为 `x86_64` 重新编译 `better-sqlite3` 和 `node-pty`
7. 用 Intel 版本替换内置的 ARM 二进制，例如 `codex` 和 `rg`
8. 对重建后的应用做 ad-hoc 签名
9. 打包输出 `./Codex-Intel.dmg`

## 故障排查

如果构建失败，查看 `log.txt`。

## 说明

- 官方 Codex 二进制、商标和相关资源归 OpenAI 所有
- 本仓库与 OpenAI 没有关联，也未获得其认可
- 按照 [LICENSE](./LICENSE) 中的 MIT 条款开放
