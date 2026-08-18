# AIChatApp — 未签名 IPA 编译包

这是一个纯 SwiftUI 的 iOS AI 对话应用（联网 API + 本地离线推理双模式）。
本目录已经把你上传的压缩包整理成**可直接编译出未签名 IPA** 的工程。

> ⚠️ 重要前提：iOS App **只能在 macOS 上编译**（需要 Xcode 提供的 iOS SDK）。
> 如果你手头没有 Mac，请直接跳到下方「方式二：用 GitHub 云主机编译」。

---

## 目录结构

```
AIChatApp-build/
├── project.yml                      # XcodeGen 工程描述（核心）
├── build_ipa.sh                     # 一键编译脚本（macOS 本地用）
├── .github/workflows/build-ipa.yml  # GitHub Actions 云编译（无 Mac 也能用）
├── Sources/                         # 全部 Swift 源码（原样保留）
├── SupportingFiles/
│   ├── Info.plist                   # 原始 plist（作参考，编译时由 XcodeGen 重新生成完整版）
│   └── Assets.xcassets/             # App 图标、启动色、强调色
└── edge_functions/                  # Supabase 云函数（联网技能用，与 IPA 编译无关）
```

**说明**：原来的 `Package.swift` 是纯 SPM 描述，不能直接产出带图标/Info.plist 的 `.ipa`；
因此改用 XcodeGen（`project.yml`）生成标准 iOS 工程，依赖项（llama.cpp）保持不变。

---

## 方式一：在 Mac 上本地编译（推荐，最快）

1. 准备环境（只需一次）：
   ```bash
   # 安装 Xcode（App Store）
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   # 安装 XcodeGen
   brew install xcodegen
   ```

2. 进入本目录，运行：
   ```bash
   chmod +x build_ipa.sh
   ./build_ipa.sh
   ```

3. 编译完成后，产物在：
   ```
   build/AIChatApp-unsigned.ipa
   ```

首次编译需要联网拉取并编译 `llama.cpp`（较大的 C++ 库），耗时可能较长，请耐心等待。

---

## 方式二：没有 Mac，用 GitHub 云主机编译（免费）

1. 把整个 `AIChatApp-build` 目录初始化为 Git 仓库并推到 GitHub：
   ```bash
   cd AIChatApp-build
   git init
   git add -A
   git commit -m "AIChatApp SwiftUI"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/AIChatApp.git
   git push -u origin main
   ```

2. 打开仓库的 **Actions** 页签，找到 `Build unsigned IPA` 工作流，点击 **Run workflow** 手动触发。

3. 编译成功后，进入该次运行，在底部 **Artifacts** 下载 `AIChatApp-unsigned`（解压即得 `.ipa`）。

> 注意：GitHub Actions 对公开仓库免费；私有仓库也有每月免费额度。
> 若 llama.cpp 在 CI 上编译失败，通常是网络/内存问题，重跑一次即可。

---

## 关于签名（你自己处理）

编译产物是**未签名 IPA**，安装前需要自行签名，常见做法：

| 方式 | 适用场景 | 说明 |
|---|---|---|
| Xcode + Apple Developer 证书 | 有开发者账号 | `fastlane sigh` 或 Xcode 重新签名 |
| AltStore / SideStore | 普通用户侧载 | 用 Apple ID 免开发者账号签名（7 天有效期） |
| `ldid` | 越狱设备 | 直接对 `.app` 内二进制签名 |

---

## 关键参数（如需改动）

| 项 | 位置 | 默认值 |
|---|---|---|
| Bundle ID | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER` | `com.aichat.app` |
| 最低系统 | `project.yml` → `deploymentTarget` | iOS 16.0 |
| App 显示名 | `project.yml` → `CFBundleDisplayName` | AI 对话助手 |
| llama.cpp 版本 | `project.yml` → `packages` | branch: master |
