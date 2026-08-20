import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsVM: SettingsViewModel

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
                                title: "AI 回复自动朗读",
                                subtitle: "生成完成后自动用系统语音朗读（本地合成，无需网络）",
                                isOn: ttsBinding
                            )
                            Divider().background(AppTheme.divider)
                            toggleRow(
                                title: "逐字震动反馈",
                                subtitle: "生成每个字时触发极短震动（可在安静环境关闭）",
                                isOn: hapticBinding
                            )
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

                    // 智能工具流程（可自定义）
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

                            // 文本输入 / AI / 随机生成规则
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

                    Text("联网功能（搜索 / 图片生成 / 天气 / 网页摘要）已内置，使用公开免密钥接口，无需配置任何后端。")
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

// MARK: - 文本输入 / AI / 随机生成「智能工具流程」规则
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
                    Text("描述你想要的规则")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.secondaryText)
                    Text("例如：\"当用户想找附近好吃的餐厅时，先获取位置，再搜索美食推荐\"")
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
                            Text("在这里输入你想要的规则描述…")
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
                    Label(isGenerating ? "生成中…" : "让 AI 生成规则", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.userBubbleText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isGenerating || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // 随机生成
                Button {
                    generateRandom()
                } label: {
                    Label("随机生成 3 条规则", systemImage: "dice.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.accent)
                }

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
        let sys = """
        你是「智能工具流程」方案生成器。用户会描述一个使用场景，请为其设计 1~4 条常用工具流程方案。
        只输出一个 JSON 数组，不要任何解释、不要 Markdown 代码块、不要其它文字。格式如下：
        [{"name":"方案名","trigger":"触发场景描述","steps":[{"tool":"location"},{"tool":"search","param":"附近 好玩的景点"}]}]
        要求：tool 只能是 location / search / weather / web / image / system 之一；location 不需要 param，其它工具建议给中文 param。
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

    private func generateRandom() {
        let pool: [(String, String, [ToolStep])] = [
            ("推荐景点", "用户想找当地 / 附近好玩的地方、旅游景点", [ToolStep(tool: .location), ToolStep(tool: .search, param: "附近 好玩的景点推荐")]),
            ("天气咨询", "询问天气、气温、是否下雨、穿衣出行建议", [ToolStep(tool: .location), ToolStep(tool: .weather, param: "我的位置")]),
            ("周边美食", "想找附近 / 当地好吃的、餐厅推荐", [ToolStep(tool: .location), ToolStep(tool: .search, param: "附近 美食餐厅推荐")]),
            ("实时资讯", "询问最新新闻、时事、实时信息", [ToolStep(tool: .search, param: "今天的最新热点新闻")]),
            ("网页速览", "想了解某个网页 / 链接的内容摘要", [ToolStep(tool: .web, param: "https://example.com")]),
            ("生成图片", "想要一张图 / 配图 / 插画", [ToolStep(tool: .image, param: "a beautiful landscape")]),
            ("出行路线", "询问怎么去某地、交通路线", [ToolStep(tool: .location), ToolStep(tool: .search, param: "从当前位置出发的路线")]),
            ("系统操作", "调节亮度 / 音量、开关手电筒、跳转系统设置", [ToolStep(tool: .system, param: "brightness 50")]),
        ]
        let existingNames = Set(settingsVM.settings.workflows.map { $0.name })
        let candidates = pool.filter { !existingNames.contains($0.0) }
        guard !candidates.isEmpty else {
            message = "所有内置规则都已存在，无法随机生成新的"
            messageTint = AppTheme.warning
            return
        }
        let presets = candidates.shuffled().prefix(3).map { WorkflowPreset(name: $0.0, trigger: $0.1, steps: $0.2) }
        settingsVM.settings.workflows.append(contentsOf: presets)
        settingsVM.save()
        message = "已随机添加 \(presets.count) 条新规则 🎲"
        messageTint = AppTheme.success
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
