# Pasteboard

[![CI](https://github.com/xiaoosnggao/paste/actions/workflows/ci.yml/badge.svg)](https://github.com/xiaoosnggao/paste/actions/workflows/ci.yml)
[![Release](https://github.com/xiaoosnggao/paste/actions/workflows/release.yml/badge.svg)](https://github.com/xiaoosnggao/paste/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

macOS 剪贴板历史管理工具,支持 OCR 文字识别、翻译、截图取词与 MCP 集成,基于 Swift Package 构建。

## 功能

- **剪贴板历史**:自动记录文本、图片、链接、颜色、文件,默认快捷键 `⇧⌘V` 呼出面板
- **直接粘贴**:开启辅助功能权限后,双击卡片或按回车即可粘贴到目标应用
- **OCR 文字识别**:系统识别,也可配置火山、腾讯、百度、Google、OpenAI 兼容服务
- **翻译**:系统翻译,以及智谱、OpenAI 兼容、有道、Google、微软等服务;支持选中文字翻译
- **截图识别 / 截图翻译**:截屏后直接 OCR 或翻译
- **翻译窗口**:回车翻译、`⇧↩` 换行、`⌘R` 重试、`⌘P` 固定窗口
- **MCP 服务**:内置 `PasteboardMCP` 可执行程序,可接入 Claude 等 MCP 客户端
- **隐私**:服务密钥保存在系统钥匙串,历史记录保存在本地

## 系统要求

- macOS 14 及以上,Apple Silicon 芯片
- 系统翻译功能需要 macOS 15 及以上,首次使用需下载语言包
- 截图识别/翻译需要屏幕录制权限;直接粘贴、选中文字翻译需要辅助功能权限(应用内提供授权引导)

## 下载安装

前往 [Releases](https://github.com/xiaoosnggao/paste/releases) 下载最新 DMG,将 Pasteboard.app 拖入「应用程序」文件夹。

安装包采用临时签名(未做 Developer ID 公证),首次打开如遇 Gatekeeper 拦截,可执行:

```bash
xattr -cr /Applications/Pasteboard.app
```

## 从源码构建

构建需要 Xcode 26.4 或更新版本及完整 macOS SDK；CI 使用 Xcode 26.6。运行要求仍为 macOS 14 或更新版本。

```bash
git clone https://github.com/xiaoosnggao/paste.git
cd paste

# 编译
swift build

# 运行测试
swift test

# 构建 .app(输出到 dist/Pasteboard.app)
scripts/build-app.sh release

# 打包 DMG(输出到 dist/,含 sha256)
scripts/build-dmg.sh
```

## 架构

```
Sources/
├── PasteCore/     # 核心库:数据模型、快照仓库、MCP 协议、文本工具
├── PasteMac/      # 主程序:剪贴板监听、面板 UI、OCR/翻译、快捷键、系统集成
└── PasteCLI/      # PasteboardMCP:MCP 服务可执行程序
Tests/
└── PasteCoreTests/
scripts/           # 构建与打包脚本
Resources/         # Info.plist、图标、示例文件
```

## 贡献

欢迎提交 Issue 和 Pull Request。

## License

[MIT](LICENSE) © xiaoosnggao

### 保留更新后的隐私授权

发布版本应持续使用同一代码签名证书：

```bash
PASTEBOARD_SIGNING_IDENTITY="Developer ID Application: 名称 (TEAMID)" scripts/build-app.sh release
```

本机构建也可在项目根目录 `.signing-identity` 中保存证书指纹（此文件不提交到 Git）；环境变量优先。两者都未设置时生成临时签名构建。临时签名的程序身份随内容变化，不能保证更新后保留辅助功能和屏幕录制授权。固定安装位置为 `/Applications/Pasteboard.app`，更新前先退出旧进程。应用不会在启动时请求或写入系统授权，也不自动删除隐私记录。
