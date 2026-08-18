import SwiftUI

/// 对话列表面板（抽屉式 Sheet）：切换 / 新建 / 删除对话。
/// 在线与离线共享同一列表，每条对话独立上下文。
struct ConversationListView: View {
    @EnvironmentObject var store: ConversationStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                if store.conversations.isEmpty {
                    Text("还没有对话")
                        .foregroundColor(AppTheme.secondaryText)
                        .padding(.top, 60)
                }
                List {
                    ForEach(store.conversations) { conv in
                        ConversationRow(conv: conv, isCurrent: conv.id == store.currentId)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    store.select(conv.id)
                                    isPresented = false
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        store.delete(conv.id)
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.top, 6)
            }
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation { isPresented = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(AppTheme.secondaryText)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            store.createConversation(mode: store.currentMode)
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
    }
}

/// 单条对话行
struct ConversationRow: View {
    let conv: Conversation
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isCurrent ? AppTheme.accent.opacity(0.16) : AppTheme.surfaceElevated)
                Image(systemName: conv.mode == .online ? "globe" : "cpu")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isCurrent ? AppTheme.accent : AppTheme.secondaryText)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                    .lineLimit(1)
                Text(conv.preview)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.accent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isCurrent ? AppTheme.accent.opacity(0.12) : AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isCurrent ? AppTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }
}
