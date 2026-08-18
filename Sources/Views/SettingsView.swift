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

                    Text("提示：联网功能（搜索、图片生成、语音合成）通过云端函数调用，需配置后端服务。")
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