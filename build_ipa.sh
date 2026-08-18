#!/bin/bash
#
# AIChatApp 未签名 IPA 一键编译脚本（仅 macOS + Xcode）
#
# 用法：
#   chmod +x build_ipa.sh && ./build_ipa.sh
#
# 产物：
#   build/AIChatApp-unsigned.ipa   ← 未签名 IPA，可自行签名后侧载
#
set -euo pipefail

SCHEME="AIChatApp"
CONFIGURATION="Release"
DERIVED_DATA=".build"
ARCHIVE_PATH="build/AIChatApp.xcarchive"
IPA_PATH="build/AIChatApp-unsigned.ipa"

echo "=================================================="
echo " AIChatApp 未签名 IPA 编译"
echo "=================================================="

# 1. 检查环境
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "❌ 未找到 xcodebuild。本脚本必须在 macOS 上运行，并已安装 Xcode。"
  echo "   安装后还需执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

# 2. 检查/安装 XcodeGen
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ℹ️  未找到 xcodegen，尝试通过 Homebrew 安装..."
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "❌ 未安装 Homebrew，请先手动安装 XcodeGen："
    echo "   https://github.com/yonaskolb/XcodeGen"
    exit 1
  fi
fi

# 3. 生成 Xcode 工程
echo "ℹ️  生成 Xcode 工程..."
xcodegen generate

# 4. 编译归档（关闭代码签名）
echo "ℹ️  开始编译（未签名），llama.cpp 较大，首次编译可能耗时较久..."
xcodebuild \
  -project AIChatApp.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive

# 5. 打包 IPA（标准 Payload 结构）
echo "ℹ️  打包未签名 IPA..."
APP_PATH="$ARCHIVE_PATH/Products/Applications/AIChatApp.app"
if [ ! -d "$APP_PATH" ]; then
  echo "❌ 未找到编译产物：$APP_PATH"
  exit 1
fi

rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/
rm -f "$IPA_PATH"
(cd build && zip -qry AIChatApp-unsigned.ipa Payload)
rm -rf build/Payload

echo ""
echo "=================================================="
echo " ✅ 完成：$IPA_PATH"
echo "=================================================="
echo " 说明：该 IPA 未签名。可用以下任一方式自行签名："
echo "   - Xcode / Apple Developer 证书 + fastlane sigh"
echo "   - AltStore / SideStore 侧载"
echo "   - 越狱设备用 ldid 直接签名"
