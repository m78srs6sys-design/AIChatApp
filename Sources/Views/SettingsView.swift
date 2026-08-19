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
                                title: "允许 AI 调用联网功能",
                                subtitle: "开启后，AI 可在需要时主动搜索、查天气、读网页、生成图片",
                                isOn: onlineFeaturesBinding
                            )
                            Divider().background(AppTheme.divider)
                            toggleRow(
                                title: "逐字震动反馈",
                                subtitle: "生成每个字时触发极短震动（可在安静环境关闭）",
                                isOn: hapticBinding
                            )
                        }
                    }

                    // 智能工具流程（可自定义）
                    section(title: "智能工具流程（可自定义）") {
                        VStack(spacing: 12) {
                            Text("像搭积木一样组合工具：设定「什么场景 → 先做什么、再做什么」，AI 会按你设定的顺序调用工具。内置方案可改、可删、可新增。")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach($settingsVM.settings.workflows) { $preset in
                                let p = preset.wrappedValue
                                HStack(alignment: .top, spacing: 10) {
                                    Toggle(isOn: $preset.enabled) { EmptyView() }
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
            .background(AppTheme.surface)
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

    // MARK: - 智能工具流程编辑状态
    @State private var showEditor = false
    @State private var editingId: UUID? = nil
    @State private var draft: WorkflowPreset = .empty

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
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5))
        }
    }
}

// MARK: - 工具流程编辑器（新建 / 编辑方案）
struct WorkflowEditor: View {
    @Binding var preset: WorkflowPreset
    let onSave: (WorkflowPreset) -> Void
    let onCancel: () -> Void

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

            ForEach(Array(preset.wrappedValue.steps.indices), id: \.self) { i in
                WorkflowStepCard(
                    step: $preset.steps[i],
                    index: i,
                    total: preset.wrappedValue.steps.count,
                    onMoveUp: { moveStep(i, to: i - 1) },
                    onMoveDown: { moveStep(i, to: i + 1) },
                    onDelete: { preset.steps.wrappedValue.remove(at: i) }
                )
            }

            Button {
                preset.steps.wrappedValue.append(ToolStep(tool: .search, param: ""))
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
        guard to >= 0, to <= preset.wrappedValue.steps.count else { return }
        preset.wrappedValue.steps.move(fromOffsets: [from], toOffset: to)
    }

    private func saveAndDismiss() {
        var r = preset.wrappedValue
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
                .background(AppTheme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            toolPicker
            paramRow
        }
        .padding(12)
        .background(AppTheme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        if step.wrappedValue.tool.needsParam {
            TextField("参数（如：附近 景点 推荐 / 我的位置）", text: $step.param)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("该工具无需参数")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.tertiaryText)
        }
    }
}
