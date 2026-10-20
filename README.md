# Pasteboard

[![CI](https://github.com/xiaoosnggao/paste/actions/workflows/ci.yml/badge.svg)](https://github.com/xiaoosnggao/paste/actions/workflows/ci.yml)
[![Release](https://github.com/xiaoosnggao/paste/actions/workflows/release.yml/badge.svg)](https://github.com/xiaoosnggao/paste/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

macOS 剪贴板历史管理工具,支持 OCR 文字识别、翻译、截图取词与 MCP 集成,基于 Swift Package 构建。

## 功能

- **剪贴板历史**:自动记录文本、图片、链接、颜色、文件，默认永久保留，无历史条数上限；`⇧⌘V` 呼出面板
- **直接粘贴**:开启辅助功能权限后,双击卡片或按回车即可粘贴到目标应用
- **OCR 文字识别**:系统识别,也可配置火山、腾讯、百度、Google、OpenAI 兼容服务
- **翻译**:系统翻译,以及智谱、OpenAI 兼容、有道、Google、微软等服务;支持选中文字翻译
- **截图识别 / 截图翻译**:截屏后直接 OCR 或翻译
- **翻译窗口**:停止输入 0.75 秒自动翻译、回车立即翻译、`⇧↩` 换行、`⌘R` 重试、`⌘P` 固定窗口
- **MCP 服务**:内置 `PasteboardMCP` 可执行程序,可接入 Claude 等 MCP 客户端
- **隐私**:服务密钥保存在系统钥匙串,历史记录保存在本地

## AI 场景建议

在设置 → AI 服务中添加文本模型后，选中一张文本卡片即可生成 3–5 个处理建议。建议结合卡片内容、来源应用和打开剪贴板前的目标应用，例如格式化 JSON、生成类型或调整消息语气。

建议栏从加载时展开，使用等高骨架和带两行说明的卡片。鼠标悬停在剪贴板或建议卡片上时，上下滚轮可横向浏览；横向滚轮和触控板手势也可使用。点击选项或按 `⌥1–5` 处理并粘贴。原卡片保留，处理结果另存为关联卡片；没有可用输入框时复制结果。切换卡片或关闭面板会取消旧请求。

使用当前选中的 AI 翻译服务；未指定时使用首个已启用的文本服务。可在 AI 服务设置中关闭自动建议。请求只包含所选文本与已知的应用名称、标识，不包含其他历史或窗口内容。单卡建议处理最多 8,192 个字符或 32 KB 文本；多卡任务完整分块处理长文，显示进度并支持取消。

多选卡片后显示一句话摘要、可展开要点与 3–5 个建议。金额、日期和冲突信息保留，来源可回看；处理结果先预览编辑，再复制、粘贴或另存，关联全部原卡片。

## 本地知识库

历史以 SQLite 增量保存，原始格式和图片保存在本地附件目录；升级时保留原 JSON 与迁移备份。列表分页读取，历史不会因条数、期限或总容量自动删除。磁盘不足会报告保存失败，支持重试。

新增或修改内容后，应用使用 macOS 本地句向量模型后台建立索引，不调用云端 embedding，也不借助其他 AI 应用读取历史。模型不可用时关键词搜索仍可用。支持的语言由本机模型决定，中英文使用独立索引空间；中文语义排序可能不精确，关键词与来源/时间筛选会共同参与搜索。

在搜索框输入“从微信复制的报价”“上周的链接”等描述可筛选；输入“把链接归到项目资料”“删除昨天的截图”“总结上周的报价”后按回车，先查看范围再执行。删除可撤销。批量操作仅采用明确关键词与筛选条件，不自动包含语义相近的其他记录。

新内容按已有分类在本地匹配；明确匹配时自动归入，模糊时在卡片右键菜单提供候选。手动分类和移出操作优先。右键分类 →“自动归类设置…”可填写说明、关键词或关闭该分类的自动归类；总开关位于设置 → 通用。升级前的历史只建索引，不会擅自重新分类。当前中文自动归类采用明确关键词与具体分类名规则，语义模型只提供候选。

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
