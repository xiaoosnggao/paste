#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${PASTEBOARD_APP_SOURCE:-"$ROOT/dist/Pasteboard.app"}
if [ ! -d "$APP" ]; then
    printf '%s\n' 'Build the release app with scripts/build-app.sh release first.' >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Pasteboard" | tr ' ' '-')
DMG="$ROOT/dist/Pasteboard-$VERSION-$ARCH.dmg"
STAGING=$(mktemp -d "$ROOT/dist/.dmg-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
ditto "$APP" "$STAGING/Pasteboard.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'README'
Pasteboard

安装：将 Pasteboard.app 拖入“应用程序”文件夹，然后打开。
打开剪贴板：默认快捷键为 ⇧⌘V。
直接粘贴：双击卡片或按回车粘贴。首次使用时，按照引导开启辅助功能权限；没有目标输入框时自动复制。

识别与翻译：默认使用系统文字识别和系统翻译。系统翻译需要 macOS 15 或更新版本，首次使用需下载语言包。
在设置的“识别与翻译”中，可配置火山、腾讯、百度、Google 和 OpenAI 兼容文字识别服务，以及智谱、OpenAI 兼容、有道、Google 和微软翻译服务。密钥保存在系统钥匙串中。
截图识别和截图翻译需要屏幕录制权限；选中文字翻译需要辅助功能权限。首次使用时会显示授权引导。
原图与识别文字、原文与译文分别保存为独立卡片。

快捷键：在设置的“快捷键”中配置。识别与翻译功能默认不绑定全局快捷键。
翻译窗口：停止输入 0.75 秒自动翻译，回车立即翻译，⇧↩ 换行，⌘R 重试，⌘P 固定窗口，Esc 关闭。

系统要求：macOS 14 或更新版本，Apple Silicon 芯片。
此安装包尚未完成 Apple 公证。
iCloud 同步和共享暂未提供。无内购或订阅。
README
if codesign --display --verbose=2 "$APP" 2>&1 | /usr/bin/grep -q 'Signature=adhoc'; then
    printf '\n%s\n' '签名：临时签名。更新后可能需要重新授权。' >> "$STAGING/安装说明.txt"
else
    printf '\n%s\n' '签名：证书签名。请持续使用同一签名身份更新应用。' >> "$STAGING/安装说明.txt"
fi
hdiutil create -volname Pasteboard -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
printf '%s\n' "$DMG"
