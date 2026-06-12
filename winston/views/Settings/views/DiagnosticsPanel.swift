//
//  DiagnosticsPanel.swift
//  winston
//
//  On-device debug tools and log export.
//

import SwiftUI
import UIKit

struct DiagnosticsPanel: View {
  @ObservedObject private var diagnostics = AppDiagnostics.shared
  @ObservedObject private var wire = RedditWire.shared
  @Environment(\.useTheme) private var theme

  @State private var exportURL: URL?
  @State private var isSharingExport = false
  @State private var isExporting = false
  @State private var snapshotText = ""
  @State private var showClearAlert = false
  @State private var showResetGraphQLAlert = false

  var body: some View {
    List {
      Section("Live State") {
        DiagnosticRow(label: "Session", value: diagnostics.currentSessionID)
        DiagnosticRow(label: "Reddit", value: wire.status)
        DiagnosticRow(label: "Connected", value: wire.connected ? "yes" : "no")
        DiagnosticRow(label: "Account", value: wire.account.map { "u/\($0.username)" } ?? "none")
        DiagnosticRow(label: "Accounts", value: "\(wire.accounts.count)")
        Toggle("Debug HUD", isOn: $diagnostics.overlayEnabled)
      }

      Section("Export") {
        WListButton {
          Task { await exportDiagnostics() }
        } label: {
          Label(isExporting ? "Preparing Export..." : "Export Diagnostics Bundle", systemImage: "square.and.arrow.up")
        }
        .disabled(isExporting)

        WListButton {
          Task {
            let text = await diagnostics.snapshotText()
            UIPasteboard.general.string = text
            diagnostics.record(.info, category: "diagnostics", message: "Copied diagnostics snapshot")
          }
        } label: {
          Label("Copy Snapshot", systemImage: "doc.on.doc")
        }
      }

      Section("Breadcrumbs") {
        WListButton {
          diagnostics.breadcrumb("Manual marker from Diagnostics screen")
        } label: {
          Label("Add Manual Marker", systemImage: "mappin.and.ellipse")
        }

        WListButton {
          diagnostics.breadcrumb("Settings route smoke start")
          for route in Router.NavDest.Setting.allDiagnosticsRoutes {
            diagnostics.breadcrumb("Settings route available", metadata: ["route": route.rawValue])
          }
          diagnostics.breadcrumb("Settings route smoke end")
        } label: {
          Label("Record Settings Route Smoke", systemImage: "checklist")
        }
      }

      Section("Recovery") {
        WListButton {
          showResetGraphQLAlert = true
        } label: {
          Label("Reset GraphQL Account State", systemImage: "person.crop.circle.badge.xmark")
            .foregroundStyle(.red)
        }

        WListButton {
          showClearAlert = true
        } label: {
          Label("Clear Diagnostic Logs", systemImage: "trash")
            .foregroundStyle(.red)
        }
      }

      Section("Recent Events") {
        ForEach(diagnostics.entries.suffix(80).reversed()) { entry in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(entry.level.rawValue.uppercased())
                .fontSize(11, .semibold)
                .foregroundStyle(color(for: entry.level))
              Text(entry.category)
                .fontSize(12, .semibold)
                .opacity(0.65)
              Spacer()
            }
            Text(entry.message)
              .fontSize(14, .regular)
              .textSelection(.enabled)
            Text(entry.timestamp)
              .fontSize(11, .regular)
              .opacity(0.45)
          }
          .padding(.vertical, 4)
        }
      }
    }
    .themedListSection()
    .themedListBG(theme.lists.bg)
    .scrollContentBackground(.hidden)
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      diagnostics.breadcrumb("Opened Diagnostics panel")
      Task { snapshotText = await diagnostics.snapshotText() }
    }
    .sheet(isPresented: $isSharingExport) {
      if let exportURL {
        ShareSheet(items: [exportURL])
      }
    }
    .alert("Clear diagnostic logs?", isPresented: $showClearAlert) {
      Button("Clear Logs", role: .destructive) {
        diagnostics.clearLogs()
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Reset GraphQL account state?", isPresented: $showResetGraphQLAlert) {
      Button("Reset", role: .destructive) {
        Task { await RedditWire.shared.debugResetGraphQLSessionState() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This clears GraphQL account records and stored sessions. It does not reset themes or general preferences.")
    }
  }

  private func exportDiagnostics() async {
    isExporting = true
    diagnostics.breadcrumb("Diagnostics export requested")
    exportURL = await diagnostics.exportBundle()
    isExporting = false
    isSharingExport = exportURL != nil
  }

  private func color(for level: DiagnosticLevel) -> Color {
    switch level {
    case .debug: return .secondary
    case .info: return .accentColor
    case .warning: return .orange
    case .error, .fault: return .red
    }
  }
}

private struct DiagnosticRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
      Spacer(minLength: 12)
      Text(value)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }
}

struct DiagnosticsHUD: View {
  @ObservedObject private var diagnostics = AppDiagnostics.shared
  @ObservedObject private var wire = RedditWire.shared

  var body: some View {
    if diagnostics.overlayEnabled {
      VStack(alignment: .leading, spacing: 4) {
        Text("Diagnostics")
          .fontSize(11, .bold)
        Text(wire.status)
          .lineLimit(2)
          .fontSize(11, .medium)
        if let last = diagnostics.entries.last {
          Text("\(last.category): \(last.message)")
            .lineLimit(2)
            .fontSize(10, .regular)
            .opacity(0.8)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
      .padding(.top, 8)
      .padding(.leading, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
    }
  }
}

private extension Router.NavDest.Setting {
  static var allDiagnosticsRoutes: [Router.NavDest.Setting] {
    [
      .general,
      .behavior,
      .appearance,
      .accounts,
      .diagnostics,
      .about,
      .faq,
      .themes,
      .appIcon,
      .themeStore,
      .commentSwipe,
      .postSwipe,
      .accessibility,
      .filteredSubreddits
    ]
  }
}
