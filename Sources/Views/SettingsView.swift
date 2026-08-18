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

                    // iCloud 同步状态提示
                    HStack(spacing: 6) {
                        Image(systemName: ICloudSettingsStore.isUsingiCloud ? "icloud.fill" : "icloud.slash")
                            .font(.system(size: 12))
                        Text(ICloudSettingsStore.isUsingiCloud
                             ? "设置已同步至 iCloud：卸载重装后自动恢复"
                             : "iCloud 不可用，设置仅保存在本机（重装需重填）")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(ICloudSettingsStore.isUsingiCloud ? AppTheme.success : AppTheme.warning)
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
    }

    @ViewBuilder
    private func section<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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