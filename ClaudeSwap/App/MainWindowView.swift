//
//  MainWindowView.swift
//  ClaudeSwap
//
//  Sidebar + content shell for the main window, shown once onboarding has
//  completed. Each sidebar row maps 1:1 to an `AppTab`.
//

import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        NavigationSplitView {
            List(AppTab.allCases, selection: $appModel.selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter()
                    .padding(AppSpacing.sm)
            }
        } detail: {
            NavigationStack {
                content(for: appModel.selectedTab)
                    .navigationTitle(appModel.selectedTab.title)
            }
        }
        .overlay(alignment: .top) {
            if let message = appModel.errorBanner {
                ErrorBanner(message: message) { appModel.dismissError() }
                    .padding(.top, AppSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: appModel.errorBanner)
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard: DashboardView()
        case .accounts: AccountsView()
        case .automation: AutomationView()
        case .activity: ActivityView()
        case .tools: ToolsView()
        case .settings: SettingsView()
        }
    }
}

private struct ConnectionFooter: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ConnectionIndicator(state: indicatorState)
    }

    private var indicatorState: ConnectionIndicator.State {
        switch appModel.connectionState {
        case .connecting: return .connecting
        case .connected: return .connected
        case .fixtureMode: return .fixture
        case .disconnected: return .disconnected
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.status(.critical))
            Text(message)
                .font(AppTypography.subheadline)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
        }
        .padding(AppSpacing.sm)
        .background(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusMedium).fill(AppColors.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusMedium).strokeBorder(AppColors.divider))
        .padding(.horizontal, AppSpacing.md)
        .shadow(radius: 6, y: 2)
    }
}
