import SwiftUI
import UIKit
import CoreLocation
import CoreMotion
import UserNotifications
import AVFoundation

/// 权限行标识（用于匹配本地权限状态文本）
enum PermissionKey {
    static let location = "location"
    static let motion = "motion"
    static let mic = "mic"
    static let notification = "notification"
}

struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel
    /// 检查更新服务（GitHub Releases 拉取最新 IPA）
    @ObservedObject private var release = ReleaseFetcher.shared
    @State private var showUpdateShare = false

    /// 系统权限状态文本（位置 / 运动与健身 / 麦克风 / 通知）
    @State private var locationAuthText = "检测中…"
    @State private var motionAuthText = "检测中…"
    @State private var micAuthText = "检测中…"
    @State private var notifAuthText = "检测中…"

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    // 联网 API 设置
                    section(title: "联网 API 设置") {
                        VStack(spacing: 14) {
                            Menu {
                                ForEach(APIPreset.allCases) { preset in
                                    Button(preset.name) {
                                        settingsVM.settings.apiURL = preset.url
                                        settingsVM.settings.modelName = preset.model
                                        settingsVM.settings.engine = .openAICompatible
                                    }
                                }
                            } label: {
                                Label("快速填入预设接口", systemImage: "wand.and.stars")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            settingField(title: "接口地址", placeholder: "https://api.example.com", text: $settingsVM.settings.apiURL)
                            settingField(title: "API 密钥", placeholder: "sk-...", text: $settingsVM.settings.apiKey, secure: true)
                            settingField(title: "模型名称", placeholder: "gpt-4o-mini", text: $settingsVM.settings.modelName)

                            // 模型名填写提示（百炼/通义常见坑：连字符 vs 点号）
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                Text("百炼/通义模型名用「连字符」，如 qwen3-8b、qwen-plus；不要写成 qwen3.8（点号会报 model_not_found）。")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(AppTheme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("深度思考字段类型")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.secondaryText)
                                Picker("", selection: $settingsVM.settings.deepThinkingField) {
                                    ForEach(DeepThinkingField.allCases, id: \.self) { f in
                                        Text(f.displayName).tag(f)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }

                    // 本地模型管理入口
                    section(title: "本地离线模型") {
                        NavigationLink(value: AppRoute.models) {
                            HStack {
                                Image(systemName: "cpu.filled")
                                    .foregroundColor(AppTheme.accent)
                                Text("模型下载与管理")
                                    .foregroundColor(AppTheme.primaryText)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppTheme.tertiaryText)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 其他设置
                    section(title: "其他设置") {
                        VStack(spacing: 14) {
                            toggleRow(
                                title: "允许 AI 调用联网附加功能",
                                subtitle: "开启后，AI 可在需要时主动搜索、查天气、读网页、生成图片、操作设备",
                                isOn: onlineFeaturesBinding
                            )
                            Divider().background(AppTheme.divider)
                            toggleRow(
                                title: "模型联网搜索（内置）",
                                subtitle: "请求携带 enable_search，由模型服务端直接联网检索（通义千问等支持），不再本地拉取搜索 API，更快更稳",
                                isOn: modelWebSearchBinding
                            )
                            if true {
                                Divider().background(AppTheme.divider)
                                toggleRow(
                                    title: "AI 回复自动朗读",
                                    subtitle: "生成完成后自动用系统语音朗读（本地合成，无需网络）",
                                    isOn: ttsBinding
                                )
                            }
                            if true {
                                Divider().background(AppTheme.divider)
                                toggleRow(
                                    title: "逐字震动反馈",
                                    subtitle: "生成每个字时触发极短震动（可在安静环境关闭）",
                                    isOn: hapticBinding
                                )
                            }
                        }
                    }

                    // 检查更新（从 GitHub Releases 拉取最新 IPA 并下载到本机）
                    section(title: "检查更新") {
                        VStack(spacing: 12) {
                            Text("点击「检查更新」会连接 GitHub 仓库，拉取最新版本的 IPA 安装包并下载到本机。下载完成后用系统分享面板导出（如隔空投送 / 存储到文件），安装与签名请自行处理。")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            // 版本概览
                            HStack(spacing: 8) {
                                Image(systemName: release.hasUpdate ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(release.hasUpdate ? AppTheme.accent : AppTheme.success)
                                Text("当前版本：v\(release.currentBuild)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.primaryText)
                                Spacer()
                                if release.latestBuild > 0 {
                                    Text("线上最新：v\(release.latestBuild)")
                                        .font(.system(size: 12))
                                        .foregroundColor(AppTheme.tertiaryText)
                                }
                            }

                            if !release.lastResult.isEmpty {
                                HStack(spacing: 8) {
                                    Text(release.lastResult)
                                        .font(.system(size: 12))
                                        .foregroundColor(AppTheme.tertiaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }

                            // 检查 / 下载按钮
                            HStack(spacing: 10) {
                                Button {
                                    Task { await release.checkForUpdate() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if release.isChecking { ProgressView().tint(.white) }
                                        Text(release.isChecking ? "检查中…" : "检查更新")
                                    }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(AppTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .disabled(release.isChecking)

                                if release.hasUpdate {
                                    Button {
                                        Task {
                                            await release.downloadLatest()
                                            if release.downloadedURL != nil { showUpdateShare = true }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if release.isDownloading { ProgressView().tint(.white) }
                                            Text(release.isDownloading ? "下载中…" : "下载 IPA")
                                        }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity)
                                        .background(AppTheme.accentSoft)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .disabled(release.isDownloading)
                                }
                            }

                            if release.isDownloading {
                                ProgressView(value: release.downloadProgress)
                                    .progressViewStyle(.linear)
                                    .tint(AppTheme.accent)
                            }
                        }
                    }
                    .sheet(isPresented: $showUpdateShare) {
                        if let url = release.downloadedURL {
                            ShareSheet(items: [url])
                        }
                    }

                    // 系统权限
                    section(title: "系统权限") {
                        VStack(spacing: 12) {
                            Text("AI 调用传感器或系统操作前，都会先弹窗征求你的许可。这里可快速查看权限状态，点按任意一行前往系统设置管理。")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            let permissionDefs: [(key: String, icon: String, title: String)] = [
                                (PermissionKey.location, "location.fill", "位置（海拔 / 指南针）"),
                                (PermissionKey.motion, "figure.walk", "运动与健身（步数 / 气压）"),
                                (PermissionKey.mic, "mic.fill", "麦克风（语音输入）"),
                                (PermissionKey.notification, "bell.badge.fill", "通知（下载完成提醒）")
                            ]
                            ForEach(permissionDefs, id: \.key) { row in
                                permissionRow(icon: row.icon, title: row.title, status: permissionStatus(for: row.key))
                                Divider().background(AppTheme.divider)
                            }
                            Button {
                                openSystemSettings()
                            } label: {
                                Label("打开系统设置，统一管理全部权限", systemImage: "gearshape.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }

                    // 闪退日志
                    section(title: "闪退日志") {
                        VStack(spacing: 12) {
                            let logs = CrashLogger.logFiles
                            HStack(spacing: 8) {
                                Image(systemName: logs.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(logs.isEmpty ? AppTheme.success : AppTheme.warning)
                                Text(logs.isEmpty ? "暂无闪退记录" : "已自动记录 \(logs.count) 条闪退日志")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.primaryText)
                                Spacer()
                            }
                            if let latest = logs.first,
                               let attrs = try? FileManager.default.attributesOfItem(atPath: latest.path),
                               let modDate = attrs[.modificationDate] as? Date {
                                Text("最新记录时间：\(modDate.formatted(date: .abbreviated, time: .standard))")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.tertiaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ShareLink(item: latest) {
                                    Label("分享最近一次日志", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(AppTheme.accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(AppTheme.accent.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            Text("App 发生闪退时，日志会自动保存到「文件」App 的 AIChatApp 目录 / CrashLogs 文件夹，重启后仍可查看。")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 智能工具流程（可自定义；热更新：showWorkflows 可隐藏）
                    if true {
                        section(title: "智能工具流程（可自定义）") {
                            VStack(spacing: 12) {
                                Text("像搭积木一样组合工具：设定「什么场景 → 先做什么、再做什么」，AI 会按你设定的顺序调用工具。内置方案可改、可删、可新增。")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(settingsVM.settings.workflows) { p in
                                HStack(alignment: .top, spacing: 10) {
                                    Toggle(isOn: Binding(
                                        get: { settingsVM.settings.workflows.first(where: { $0.id == p.id })?.enabled ?? false },
                                        set: { newVal in
                                            if let idx = settingsVM.settings.workflows.firstIndex(where: { $0.id == p.id }) {
                                                settingsVM.settings.workflows[idx].enabled = newVal
                                            }
                                        }
                                    )) { EmptyView() }
                                        .labelsHidden()
                                        .toggleStyle(SwitchToggleStyle(tint: AppTheme.accent))
                                        .frame(width: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.name.isEmpty ? "（未命名方案）" : p.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(AppTheme.primaryText)
                                        if !p.trigger.isEmpty {
                                            Text(p.trigger)
                                                .font(.system(size: 11))
                                                .foregroundColor(AppTheme.tertiaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Text(p.steps.map { $0.tool.displayName }.joined(separator: " → "))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(AppTheme.accent)
                                    }
                                    Spacer(minLength: 4)
                                    Button {
                                        openEdit(p)
                                    } label: {
                                        Image(systemName: "pencil")
                                            .foregroundColor(AppTheme.secondaryText)
                                    }
                                    Button {
                                        deletePreset(p)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(AppTheme.error)
                                    }
                                }
                                .padding(.vertical, 4)
                                Divider().background(AppTheme.divider)
                            }

                            Button {
                                openEdit(nil)
                            } label: {
                                Label("添加方案", systemImage: "plus.circle.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // 文本输入 → AI 设计规则
                            Button {
                                showRuleGenerator = true
                            } label: {
                                Label("文本生成规则", systemImage: "text.bubble")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.accentSoft)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.accent.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        }
                    }

                    // 保存按钮
                    Button {
                        settingsVM.save()
                    } label: {
                        Text("保存设置")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.userBubbleText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(AppTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(BounceButtonStyle())

                    // 设置持久化状态提示
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 12))
                            Text("设置已加密保存至钥匙串：卸载重装后自动恢复")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(AppTheme.success)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                    Text("联网搜索由模型服务端内置（enable_search）提供，图片生成 / 天气 / 网页摘要使用公开免密钥接口，无需配置任何后端。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(16)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showEditor) {
            WorkflowEditor(preset: $draft) { result in
                if let id = editingId,
                   let idx = settingsVM.settings.workflows.firstIndex(where: { $0.id == id }) {
                    settingsVM.settings.workflows[idx] = result
                } else {
                    settingsVM.settings.workflows.append(result)
                }
                settingsVM.save()
                showEditor = false
            } onCancel: {
                showEditor = false
            }
        }
        .sheet(isPresented: $showRuleGenerator) {
            WorkflowRuleGeneratorSheet()
        }
        .onAppear {
            refreshPermissions()
        }
        // 从系统设置返回后自动刷新权限状态
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - 系统权限状态

    /// 根据远程配置的权限行 key 返回对应的本地状态文本（未知 key 显示通用文案）
    private func permissionStatus(for key: String) -> String {
        switch key {
        case PermissionKey.location: return locationAuthText
        case PermissionKey.motion: return motionAuthText
        case PermissionKey.mic: return micAuthText
        case PermissionKey.notification: return notifAuthText
        default: return "点按前往系统设置"
        }
    }

    private func permissionRow(icon: String, title: String, status: String) -> some View {
        Button {
            openSystemSettings()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(status.contains("已授权") ? AppTheme.success
                                    : (status.contains("拒绝") ? AppTheme.warning : AppTheme.tertiaryText))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.tertiaryText)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func refreshPermissions() {
        // 位置
        switch LocationService.shared.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: locationAuthText = "已授权"
        case .denied, .restricted: locationAuthText = "已拒绝，点按前往设置"
        default: locationAuthText = "未请求（AI 用到时询问）"
        }
        // 运动与健身（传感器：步数 / 气压）
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: motionAuthText = "已授权"
        case .denied: motionAuthText = "已拒绝，点按前往设置"
        case .restricted: motionAuthText = "受限制"
        default: motionAuthText = "未请求（AI 用到时询问）"
        }
        // 麦克风
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: micAuthText = "已授权"
        case .denied: micAuthText = "已拒绝，点按前往设置"
        default: micAuthText = "未请求"
        }
        // 通知（异步查询）
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "已授权"
            case .denied: text = "已拒绝，点按前往设置"
            default: text = "未请求"
            }
            DispatchQueue.main.async { notifAuthText = text }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    @ViewBuilder
    private func section<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.secondaryText)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(16)
            .glassify(fallback: AppTheme.surface, radius: AppTheme.cardRadius, enabled: settingsVM.settings.liquidGlassEnabled)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        }
    }

    private var onlineFeaturesBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.settings.onlineFeaturesEnabled },
            set: { settingsVM.settings.onlineFeaturesEnabled = $0; settingsVM.save() }
        )
    }

    private var modelWebSearchBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.settings.modelWebSearch },
            set: { settingsVM.settings.modelWebSearch = $0; settingsVM.save() }
        )
    }

    private var hapticBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.settings.hapticPerChar },
            set: { settingsVM.settings.hapticPerChar = $0; settingsVM.save() }
        )
    }

    private var ttsBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.settings.ttsEnabled },
            set: { settingsVM.settings.ttsEnabled = $0; settingsVM.save() }
        )
    }

    // MARK: - 智能工具流程编辑状态
    @State private var showEditor = false
    @State private var editingId: UUID? = nil
    @State private var draft: WorkflowPreset = .empty
    @State private var showRuleGenerator = false

    private func openEdit(_ preset: WorkflowPreset?) {
        draft = preset ?? .empty
        editingId = preset?.id
        showEditor = true
    }

    private func deletePreset(_ preset: WorkflowPreset) {
        settingsVM.settings.workflows.removeAll { $0.id == preset.id }
        settingsVM.save()
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: AppTheme.accent))
    }

    private func settingField(title: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.secondaryText)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15))
            .foregroundColor(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassify(fallback: AppTheme.surfaceElevated, radius: 16, enabled: settingsVM.settings.liquidGlassEnabled)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - 工具流程编辑器（新建 / 编辑方案）
struct WorkflowEditor: View {
    @Binding var preset: WorkflowPreset
    let onSave: (WorkflowPreset) -> Void
    let onCancel: () -> Void
    @EnvironmentObject var settingsVM: SettingsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    fieldBlock(title: "方案名称", placeholder: "例如：推荐景点", text: $preset.name)
                    fieldBlock(title: "适用场景 / 触发描述", placeholder: "例如：用户想找当地好玩的地方", text: $preset.trigger)

                    Toggle("启用此方案", isOn: $preset.enabled)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                        .padding(.horizontal, 4)

                    stepsSection
                }
                .padding(16)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("编辑方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { saveAndDismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("步骤（按从上到下的顺序执行）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.secondaryText)
                .padding(.horizontal, 4)

            ForEach(Array(preset.steps.indices), id: \.self) { i in
                WorkflowStepCard(
                    step: $preset.steps[i],
                    index: i,
                    total: preset.steps.count,
                    onMoveUp: { moveStep(i, to: i - 1) },
                    onMoveDown: { moveStep(i, to: i + 1) },
                    onDelete: { preset.steps.remove(at: i) }
                )
            }

            Button {
                preset.steps.append(ToolStep(tool: .search, param: ""))
            } label: {
                Label("添加步骤", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(AppTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func moveStep(_ from: Int, to: Int) {
        guard to >= 0, to <= preset.steps.count else { return }
        preset.steps.move(fromOffsets: [from], toOffset: to)
    }

    private func saveAndDismiss() {
        var r = preset
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = "未命名方案" }
        onSave(r)
    }

    private func fieldBlock(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.secondaryText)
            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .foregroundColor(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassify(fallback: AppTheme.surfaceElevated, radius: 16, enabled: settingsVM.settings.liquidGlassEnabled)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - 单个步骤卡片
struct WorkflowStepCard: View {
    @Binding var step: ToolStep
    let index: Int
    let total: Int
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var settingsVM: SettingsViewModel

    @State private var showSystemDialog = false
    @State private var systemCommandDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            toolPicker
            paramRow
        }
        .padding(12)
        .glassify(fallback: AppTheme.surfaceElevated, radius: 14, enabled: settingsVM.settings.liquidGlassEnabled)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $showSystemDialog) {
            systemCommandEditor
        }
    }

    private var headerRow: some View {
        HStack {
            Text("步骤 \(index + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.secondaryText)
            Spacer()
            HStack(spacing: 16) {
                if index > 0 {
                    Button(action: onMoveUp) { Image(systemName: "arrow.up").font(.system(size: 14)) }
                }
                if index < total - 1 {
                    Button(action: onMoveDown) { Image(systemName: "arrow.down").font(.system(size: 14)) }
                }
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 14)) }
            }
            .foregroundColor(AppTheme.secondaryText)
        }
    }

    private var toolPicker: some View {
        Picker("工具", selection: $step.tool) {
            ForEach(ToolKind.allCases) { tk in
                Text(tk.displayName).tag(tk)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var paramRow: some View {
        if step.tool == .system {
            // 系统操作：点击弹出对话框填写命令
            Button {
                systemCommandDraft = step.param
                showSystemDialog = true
            } label: {
                HStack {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.accent)
                    Text(step.param.isEmpty ? "点击编辑系统操作命令" : step.param)
                        .font(.system(size: 13))
                        .foregroundColor(step.param.isEmpty ? AppTheme.tertiaryText : AppTheme.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassify(fallback: AppTheme.surface, radius: 12, enabled: settingsVM.settings.liquidGlassEnabled)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else if step.tool.needsParam {
            TextField("参数（如：附近 景点 推荐 / 我的位置）", text: $step.param)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassify(fallback: AppTheme.surface, radius: 12, enabled: settingsVM.settings.liquidGlassEnabled)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("该工具无需参数")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.tertiaryText)
        }
    }

    /// 系统操作命令编辑器（对话框）
    private var systemCommandEditor: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("系统操作命令")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.secondaryText)
                    Text("描述想让 AI 执行什么系统操作，例如：\nbrightness 0.5 — 调节亮度至 50%\n低电量 — 打开电池设置\nwifi — 打开 Wi-Fi 设置")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $systemCommandDraft)
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .glassify(fallback: AppTheme.surfaceElevated, radius: 14, enabled: settingsVM.settings.liquidGlassEnabled)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(minHeight: 100)

                Spacer()
            }
            .padding(16)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("系统操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSystemDialog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        step.param = systemCommandDraft
                        showSystemDialog = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 文本输入 / AI 生成「智能工具流程」规则
struct WorkflowRuleGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsVM: SettingsViewModel

    @State private var text = ""
    @State private var isGenerating = false
    @State private var message: String?
    @State private var messageTint: Color = AppTheme.success

    private let engine = OnlineChatEngine()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 说明文字
                VStack(alignment: .leading, spacing: 6) {
                    Text("输入你遇到的场景或需求")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.secondaryText)
                    Text("不需要事无巨细，说清场景即可，AI 会自动帮你设计完整的工具流程。例如：\"帮我找好吃的\"、\"我不知道怎么去朋友家\"")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 文本输入框
                TextEditor(text: $text)
                    .frame(minHeight: 120, maxHeight: 200)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("例如：帮我找附近好吃的…")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.tertiaryText)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }

                // AI 生成规则
                Button {
                    generateWithAI()
                } label: {
                    Label(isGenerating ? "生成中…" : "让 AI 设计规则", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.userBubbleText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isGenerating || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(messageTint)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(16)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("生成规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func generateWithAI() {
        let desc = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return }
        isGenerating = true
        message = nil
        // 用户只需描述场景，AI 自主补全、设计多套完整流程
        let sys = """
        你是「智能工具流程」方案设计专家。用户只告诉你他遇到的一个场景或需求，你需要：
        1. 理解用户真正想达成的目标（他可能没说全，你要自己推断）；
        2. 为这个场景设计 2~4 条**不同角度**的完整工具流程方案（比如：一条先定位再搜索、一条只搜索、一条查天气前置等），覆盖用户可能提出的多种表达；
        3. 每个方案要包含：方案名（简短贴切）、触发场景描述（涵盖用户可能提到的不同说法，写详细）、以及按执行顺序排列的工具步骤。

        ## 可用工具（tool 字段只能是这些之一）
        - location：获取当前位置。**不需要 param**。
        - search：联网搜索。param 写搜索关键词（中文），如 "附近 美食 餐厅"。
        - weather：查天气。param 写 "我的位置" 或具体城市。
        - web：读取某个网页内容做摘要。param 写网址或 "用户消息中的链接"。
        - image：AI 生图。param 写英文画面描述。
        - system：执行设备系统操作。param 写命令描述，如 "brightness 50"。

        ## 输出格式（严格遵守）
        只输出一个 JSON 数组，不要任何解释、不要 Markdown 代码块、不要其它文字：
        [{"name":"方案名","trigger":"触发场景描述（写详细）","steps":[{"tool":"location"},{"tool":"search","param":"附近 美食 餐厅"}]}]

        ## 示例
        用户说「帮我找好吃的」，你可以设计：
        [{"name":"周边美食推荐","trigger":"用户想找附近的餐厅/美食/好吃的，或者在问吃饭去哪","steps":[{"tool":"location"},{"tool":"search","param":"附近 美食 餐厅 推荐"}]},
         {"name":"天气+美食综合建议","trigger":"用户既想看天气又想出去吃，比如下雨天问哪里能去","steps":[{"tool":"location"},{"tool":"weather","param":"我的位置"},{"tool":"search","param":"附近 适合现在的餐厅"}]}]

        注意：方案要结合用户实际描述，不要照抄示例；步骤数量 1~3 步即可，别太长。
        """
        Task { @MainActor in
            var raw = ""
            do {
                try await engine.streamChat(
                    messages: [
                        ChatMessage(role: .system, content: sys),
                        ChatMessage(role: .user, content: desc)
                    ],
                    settings: settingsVM.settings,
                    onToken: { raw += $0 },
                    onReasoning: nil
                )
                let presets = Self.parsePresets(raw)
                if presets.isEmpty {
                    message = "没有解析到有效规则，请说得更具体一些，或换一种说法重试"
                    messageTint = AppTheme.warning
                } else {
                    // 过滤掉已存在的同名规则
                    let existingNames = Set(settingsVM.settings.workflows.map { $0.name })
                    let newPresets = presets.filter { !existingNames.contains($0.name) }
                    if newPresets.isEmpty {
                        message = "生成的规则都已存在，试试换个描述"
                        messageTint = AppTheme.warning
                    } else {
                        settingsVM.settings.workflows.append(contentsOf: newPresets)
                        settingsVM.save()
                        message = "已添加 \(newPresets.count) 条新规则 ✅（过滤掉 \(presets.count - newPresets.count) 条重复）"
                        messageTint = AppTheme.success
                        text = ""
                    }
                }
            } catch {
                message = "生成失败：\(error.localizedDescription)"
                messageTint = AppTheme.error
            }
            isGenerating = false
        }
    }

    /// 从 AI 返回的文本中解析 JSON 数组 → WorkflowPreset 列表
    private static func parsePresets(_ raw: String) -> [WorkflowPreset] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let jsonStr = String(raw[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [WorkflowPreset] = []
        for item in arr {
            guard let name = item["name"] as? String,
                  let trigger = item["trigger"] as? String else { continue }
            var steps: [ToolStep] = []
            if let stepArr = item["steps"] as? [[String: Any]] {
                for s in stepArr {
                    guard let toolRaw = (s["tool"] as? String)?.lowercased(),
                          let tool = ToolKind(rawValue: toolRaw) else { continue }
                    let param = (s["param"] as? String) ?? ""
                    steps.append(ToolStep(tool: tool, param: param))
                }
            }
            if !steps.isEmpty {
                out.append(WorkflowPreset(name: name, trigger: trigger, steps: steps))
            }
        }
        return out
    }
}
