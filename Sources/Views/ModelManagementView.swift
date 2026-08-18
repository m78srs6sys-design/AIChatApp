import SwiftUI

struct ModelManagementView: View {
    @EnvironmentObject var modelManager: LocalModelManager

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(LocalModelCatalog.models) { model in
                        modelCard(model)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("隐私说明", systemImage: "lock.shield.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                        Text("离线模式下所有推理在设备本地完成，对话数据不会上传，无需联网即可使用。模型文件较大，建议在 Wi-Fi 环境下载。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.secondaryText)
                    }
                    .padding(16)
                    .background(AppTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                }
                .padding(16)
            }
        }
        .navigationTitle("本地模型管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private func modelCard(_ model: LocalModel) -> some View {
        let state = modelManager.downloads[model.id] ?? DownloadState(downloaded: false, progress: 0, status: .idle)
        let isActive = modelManager.activeModelId == model.id

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.primaryText)
                        if isActive {
                            Text("使用中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(AppTheme.userBubbleText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(AppTheme.success))
                        }
                    }
                    Text(model.detail)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.secondaryText)
                    Text(model.sizeText)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.tertiaryText)
                }
                Spacer()
                statusBadge(state.status)
            }

            // 进度条
            if state.status == .downloading || state.status == .paused {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.surfaceElevated)
                        .frame(height: 8)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.accent)
                            .frame(width: geo.size.width * state.progress, height: 8)
                            .overlay(
                                ShimmerView().clipShape(RoundedRectangle(cornerRadius: 6))
                                    .frame(width: geo.size.width * state.progress, height: 8)
                            )
                    }
                    .frame(height: 8)
                }
                Text("\(Int(state.progress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }

            // 操作按钮
            HStack(spacing: 10) {
                switch state.status {
                case .idle, .failed:
                    Button("下载") { modelManager.startDownload(model) }
                        .buttonStyle(PrimaryActionButtonStyle())
                case .downloading:
                    Button("暂停") { modelManager.pauseDownload(model) }
                        .buttonStyle(SecondaryActionButtonStyle())
                case .paused:
                    Button("继续") { modelManager.startDownload(model) }
                        .buttonStyle(PrimaryActionButtonStyle())
                case .completed:
                    Button(isActive ? "已选择" : "使用此模型") {
                        modelManager.setActive(model)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .opacity(isActive ? 0.5 : 1.0)
                    .disabled(isActive)
                    Spacer()
                    Button {
                        modelManager.deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(AppTheme.error)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(AppTheme.surfaceElevated))
                    }
                    .buttonStyle(BounceButtonStyle())
                }
            }

            if let err = state.error {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.error)
            }
        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
    }

    private func statusBadge(_ status: DownloadState.DownloadStatus) -> some View {
        let color: Color
        switch status {
        case .completed: color = AppTheme.success
        case .downloading: color = AppTheme.accent
        case .paused: color = AppTheme.warning
        case .failed: color = AppTheme.error
        default: color = AppTheme.tertiaryText
        }
        return Text(status.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Button Styles
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(AppTheme.userBubbleText)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(AppTheme.accent)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(AppTheme.primaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(AppTheme.surfaceElevated)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension ButtonStyle where Self == SecondaryActionButtonStyle {
    static var secondaryAction: SecondaryActionButtonStyle { SecondaryActionButtonStyle() }
}