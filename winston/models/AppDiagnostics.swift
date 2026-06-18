//
//  AppDiagnostics.swift
//  winston
//
//  Persistent on-device diagnostics for crash and UI debugging.
//

import Foundation
import UIKit
import Zip
import Darwin
import Defaults
import SwiftUI
import Pulse

enum DiagnosticLevel: String, Codable, CaseIterable {
  case debug
  case info
  case warning
  case error
  case fault
}

struct DiagnosticEntry: Identifiable, Codable, Hashable {
  let id: UUID
  let timestamp: String
  let level: DiagnosticLevel
  let category: String
  let message: String
  let metadata: [String: String]
}

@MainActor
final class AppDiagnostics: ObservableObject {
  static let shared = AppDiagnostics()

  nonisolated static func asyncRecord(
    _ level: DiagnosticLevel = .info,
    category: String,
    message: String,
    metadata: [String: String] = [:]
  ) {
    guard shouldRecord(level, category: category) else { return }
    Task { @MainActor in
      AppDiagnostics.shared.record(level, category: category, message: message, metadata: metadata)
    }
  }

  nonisolated private static func shouldRecord(_ level: DiagnosticLevel, category: String) -> Bool {
    guard level == .debug else { return true }
    switch category {
    case "ui.image", "ui.media.extract", "ui.media.setup", "ui.media.prefetch", "ui.video", "ui.video.cache", "ui.video.playerView", "ui.videoPoster":
      return false
    default:
      return true
    }
  }

  /// Cheap, side-effect-free check for whether a log at this level/category would be kept.
  /// Use this to gate construction of expensive metadata on hot paths (e.g. during scroll)
  /// so we don't build dictionaries that `asyncRecord` would only discard.
  nonisolated static func isEnabled(_ level: DiagnosticLevel, category: String) -> Bool {
    shouldRecord(level, category: category)
  }

  nonisolated static func asyncBreadcrumb(_ message: String, metadata: [String: String] = [:]) {
    Task { @MainActor in
      AppDiagnostics.shared.breadcrumb(message, metadata: metadata)
    }
  }

  @Published private(set) var entries: [DiagnosticEntry] = []
  @Published var overlayEnabled: Bool {
    didSet {
      UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayEnabledKey)
      record(.info, category: "diagnostics", message: "Debug HUD overlay \(overlayEnabled ? "enabled" : "disabled")")
    }
  }
  @Published var performanceDiagnosticsEnabled: Bool {
    didSet {
      UserDefaults.standard.set(performanceDiagnosticsEnabled, forKey: Self.performanceDiagnosticsEnabledKey)
      record(.info, category: "diagnostics", message: "Scroll/hitch diagnostics \(performanceDiagnosticsEnabled ? "enabled" : "disabled")")
    }
  }

  private static let overlayEnabledKey = "diagnostics.overlayEnabled"
  private static let performanceDiagnosticsEnabledKey = "diagnostics.performanceDiagnosticsEnabled"
  private static let dirtySessionKey = "diagnostics.sessionDirty"
  private static let sessionIDKey = "diagnostics.sessionID"
  private static let sessionStartedAtKey = "diagnostics.sessionStartedAt"
  private static let lastCrashReasonKey = "diagnostics.lastCrashReason"
  private static let lastCrashAtKey = "diagnostics.lastCrashAt"

  private let logQueue = DispatchQueue(label: "com.winston.diagnostics.log", qos: .utility)

  private let isoFormatter = ISO8601DateFormatter()
  private var sessionID = UUID().uuidString
  private var hasStarted = false

  var currentSessionID: String { sessionID }
  var logDirectory: URL { diagnosticsDirectory }
  var currentLogURL: URL { diagnosticsDirectory.appendingPathComponent("winston-diagnostics-current.jsonl") }
  var previousLogURL: URL { diagnosticsDirectory.appendingPathComponent("winston-diagnostics-previous.jsonl") }

  private var diagnosticsDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Diagnostics", isDirectory: true)
  }

  private init() {
    let defaults = UserDefaults.standard
    let legacyOverlayEnabled = defaults.bool(forKey: Self.overlayEnabledKey)
    if defaults.object(forKey: Self.performanceDiagnosticsEnabledKey) == nil, legacyOverlayEnabled {
      performanceDiagnosticsEnabled = true
      overlayEnabled = false
      defaults.set(true, forKey: Self.performanceDiagnosticsEnabledKey)
      defaults.set(false, forKey: Self.overlayEnabledKey)
    } else {
      overlayEnabled = legacyOverlayEnabled
      performanceDiagnosticsEnabled = defaults.bool(forKey: Self.performanceDiagnosticsEnabledKey)
    }
    createDirectoryIfNeeded()
    loadRecentEntries()
  }

  func startSession() {
    guard !hasStarted else { return }
    hasStarted = true
    createDirectoryIfNeeded()
    rotateLogIfNeeded()
    loadRecentEntries()

    if let crashReason = UserDefaults.standard.string(forKey: Self.lastCrashReasonKey) {
      record(
        .fault,
        category: "crash.previous",
        message: crashReason,
        metadata: ["at": UserDefaults.standard.string(forKey: Self.lastCrashAtKey) ?? "unknown"]
      )
      UserDefaults.standard.removeObject(forKey: Self.lastCrashReasonKey)
      UserDefaults.standard.removeObject(forKey: Self.lastCrashAtKey)
    }

    if UserDefaults.standard.bool(forKey: Self.dirtySessionKey) {
      record(
        .fault,
        category: "launch.previous",
        message: "Previous app session did not record a clean inactive/background transition.",
        metadata: [
          "previousSessionID": UserDefaults.standard.string(forKey: Self.sessionIDKey) ?? "unknown",
          "previousStartedAt": UserDefaults.standard.string(forKey: Self.sessionStartedAtKey) ?? "unknown"
        ]
      )
    }

    sessionID = UUID().uuidString
    UserDefaults.standard.set(sessionID, forKey: Self.sessionIDKey)
    UserDefaults.standard.set(nowString(), forKey: Self.sessionStartedAtKey)
    markSessionDirty("launch")
    record(.info, category: "session", message: "Diagnostics session started", metadata: baseMetadata())
  }

  func markSessionDirty(_ reason: String) {
    UserDefaults.standard.set(true, forKey: Self.dirtySessionKey)
    UserDefaults.standard.set(reason, forKey: "diagnostics.sessionDirtyReason")
  }

  func markSessionClean(_ reason: String) {
    UserDefaults.standard.set(false, forKey: Self.dirtySessionKey)
    record(.debug, category: "session", message: "Session checkpoint: \(reason)")
  }

  func record(
    _ level: DiagnosticLevel = .info,
    category: String,
    message: String,
    metadata: [String: String] = [:]
  ) {
    let entry = DiagnosticEntry(
      id: UUID(),
      timestamp: nowString(),
      level: level,
      category: sanitizeText(category),
      message: sanitizeText(message),
      metadata: sanitize(metadata.merging(baseMetadata()) { current, _ in current })
    )

    entries.append(entry)
    if entries.count > 300 {
      entries.removeFirst(entries.count - 300)
    }
    appendToLog(entry)
    // High-frequency perf entries stay in the JSONL only; mirroring each one into the
    // Pulse store on the main thread adds lock/IO contention that would distort the very
    // hitch measurements they carry.
    if entry.category != "perf.hitch", entry.category != "perf.scrollactivity" {
      mirrorToPulse(entry)
    }
  }

  /// Mirror app events into the Pulse store so the Network Console shows app
  /// activity interleaved with network traffic. The JSONL log stays the
  /// crash-safe source of truth.
  private func mirrorToPulse(_ entry: DiagnosticEntry) {
    let level: LoggerStore.Level
    switch entry.level {
    case .debug: level = .debug
    case .info: level = .info
    case .warning: level = .warning
    case .error: level = .error
    case .fault: level = .critical
    }
    LoggerStore.shared.storeMessage(
      label: entry.category,
      level: level,
      message: entry.message,
      metadata: entry.metadata.mapValues { .string($0) }
    )
  }

  func breadcrumb(_ message: String, metadata: [String: String] = [:]) {
    record(.debug, category: "breadcrumb", message: message, metadata: metadata)
  }

  func clearLogs() {
    flushPendingLogWrites()
    try? FileManager.default.removeItem(at: currentLogURL)
    try? FileManager.default.removeItem(at: previousLogURL)
    LoggerStore.shared.removeAll()
    entries.removeAll()
  }

  func exportBundle() async -> URL? {
    createDirectoryIfNeeded()
    flushPendingLogWrites()
    let exportID = UUID().uuidString
    let exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WinstonDiagnostics-\(exportID)", isDirectory: true)
    let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("WinstonDiagnostics-\(timestampForFilename()).zip")

    do {
      try? FileManager.default.removeItem(at: exportDirectory)
      try? FileManager.default.removeItem(at: zipURL)
      try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

      var files: [URL] = []
      if FileManager.default.fileExists(atPath: currentLogURL.path) {
        let dest = exportDirectory.appendingPathComponent(currentLogURL.lastPathComponent)
        try FileManager.default.copyItem(at: currentLogURL, to: dest)
        files.append(dest)
      }
      if FileManager.default.fileExists(atPath: previousLogURL.path) {
        let dest = exportDirectory.appendingPathComponent(previousLogURL.lastPathComponent)
        try FileManager.default.copyItem(at: previousLogURL, to: dest)
        files.append(dest)
      }

      let snapshotURL = exportDirectory.appendingPathComponent("snapshot.json")
      let snapshot = await makeSnapshot()
      let snapshotData = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
      try snapshotData.write(to: snapshotURL)
      files.append(snapshotURL)

      let recentURL = exportDirectory.appendingPathComponent("recent-events.txt")
      let recentText = entries.suffix(100).map { entry in
        "[\(entry.timestamp)] [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
      }.joined(separator: "\n")
      try recentText.write(to: recentURL, atomically: true, encoding: .utf8)
      files.append(recentURL)

      // Pulse store (network console) — credentials are redacted at capture
      // time, so the archive is safe to share.
      let pulseURL = exportDirectory.appendingPathComponent("network-logs.pulse")
      do {
        try await LoggerStore.shared.export(to: pulseURL)
        files.append(pulseURL)
      } catch {
        record(.warning, category: "diagnostics.export", message: "Pulse store export failed: \(error.localizedDescription)")
      }

      // MetricKit payloads captured alongside the logs.
      if let contents = try? FileManager.default.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: nil) {
        for url in contents where url.lastPathComponent.hasPrefix("metrickit-") {
          let dest = exportDirectory.appendingPathComponent(url.lastPathComponent)
          if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
            files.append(dest)
          }
        }
      }

      do {
        files.append(contentsOf: try RenderingReportStore.shared.exportReports(to: exportDirectory))
      } catch {
        record(.warning, category: "diagnostics.export", message: "Rendering report export failed: \(error.localizedDescription)")
      }

      try Zip.zipFiles(paths: files, zipFilePath: zipURL, password: nil, progress: nil)
      record(.info, category: "diagnostics", message: "Exported diagnostics bundle", metadata: ["file": zipURL.lastPathComponent])
      return zipURL
    } catch {
      record(.error, category: "diagnostics.export", message: error.localizedDescription)
      return nil
    }
  }

  func snapshotText() async -> String {
    let snapshot = await makeSnapshot()
    guard
      let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  private func makeSnapshot() async -> [String: Any] {
    let reddit = await RedditWire.shared.diagnosticsSnapshot()
    return [
      "app": appSnapshot(),
      "device": deviceSnapshot(),
      "reddit": reddit,
      "diagnostics": [
        "sessionID": sessionID,
        "logDirectory": diagnosticsDirectory.path,
        "currentLogExists": FileManager.default.fileExists(atPath: currentLogURL.path),
        "previousLogExists": FileManager.default.fileExists(atPath: previousLogURL.path),
        "entryCountInMemory": entries.count,
        "renderingReportCount": RenderingReportStore.shared.reportCount,
        "overlayEnabled": overlayEnabled,
        "performanceDiagnosticsEnabled": performanceDiagnosticsEnabled
      ],
      "recentEvents": entries.suffix(50).map { entry in
        [
          "timestamp": entry.timestamp,
          "level": entry.level.rawValue,
          "category": entry.category,
          "message": entry.message,
          "metadata": entry.metadata
        ] as [String: Any]
      }
    ]
  }

  private func appSnapshot() -> [String: String] {
    let bundle = Bundle.main
    let defaults = UserDefaults.standard
    let auroraMediaPrefix = "diagnostics.auroraMediaViewer."
    return [
      "version": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      "build": bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
      "bundleID": bundle.bundleIdentifier ?? "unknown",
      "selectedTab": Nav.shared.activeTab.rawValue,
      "selectedThemeID": Defaults[.ThemesDefSettings].selectedThemeID,
      "appearance.showUsernameInTabBar": "\(Defaults[.AppearanceDefSettings].showUsernameInTabBar)",
      "postsInBoxCount": "\(Defaults[.postsInBox].count)",
      "auroraMediaViewer.lastEvent": defaults.string(forKey: "\(auroraMediaPrefix)lastEvent") ?? "nil",
      "auroraMediaViewer.lastEventUnixTime": "\(defaults.double(forKey: "\(auroraMediaPrefix)lastEventUnixTime"))",
      "auroraMediaViewer.lastMetadata": defaults.string(forKey: "\(auroraMediaPrefix)lastMetadata") ?? "nil"
    ]
  }

  private func deviceSnapshot() -> [String: String] {
    let device = UIDevice.current
    return [
      "model": device.model,
      "systemName": device.systemName,
      "systemVersion": device.systemVersion,
      "name": device.name,
      "identifierForVendor": device.identifierForVendor?.uuidString ?? "unknown",
      "screen": "\(Int(ScreenMetrics.bounds.width))x\(Int(ScreenMetrics.bounds.height)) @\(ScreenMetrics.scale)x",
      "locale": Locale.current.identifier,
      "timeZone": TimeZone.current.identifier
    ]
  }

  private func baseMetadata() -> [String: String] {
    [
      "sessionID": sessionID,
      "thread": Thread.isMainThread ? "main" : "background"
    ]
  }

  private func createDirectoryIfNeeded() {
    try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
  }

  private func rotateLogIfNeeded() {
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
      let size = attrs[.size] as? NSNumber,
      size.intValue > 5_000_000
    else { return }
    try? FileManager.default.removeItem(at: previousLogURL)
    try? FileManager.default.moveItem(at: currentLogURL, to: previousLogURL)
  }

  private func loadRecentEntries() {
    guard let text = try? String(contentsOf: currentLogURL, encoding: .utf8) else { return }
    let lines = text.split(separator: "\n").suffix(200)
    let decoder = JSONDecoder()
    entries = lines.compactMap { line in
      guard let data = String(line).data(using: .utf8) else { return nil }
      return try? decoder.decode(DiagnosticEntry.self, from: data)
    }
  }

  private func appendToLog(_ entry: DiagnosticEntry) {
    let directory = diagnosticsDirectory
    let logURL = currentLogURL
    logQueue.async {
      Self.writeLogEntry(entry, to: logURL, directory: directory)
    }
  }

  private func flushPendingLogWrites() {
    logQueue.sync {}
  }

  nonisolated private static func writeLogEntry(_ entry: DiagnosticEntry, to logURL: URL, directory: URL) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(entry)
      data.append(0x0a)
      if FileManager.default.fileExists(atPath: logURL.path) {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: logURL, options: .atomic)
      }
    } catch {
      print("Diagnostics log write failed: \(error.localizedDescription)")
    }
  }

  private func sanitize(_ metadata: [String: String]) -> [String: String] {
    metadata.reduce(into: [:]) { result, item in
      let key = sanitizeText(item.key)
      result[key] = isSensitiveMetadataKey(item.key) ? "<redacted>" : sanitizeText(item.value)
    }
  }

  private func sanitizeText(_ value: String) -> String {
    return String(value.prefix(1_000))
  }

  private func isSensitiveMetadataKey(_ key: String) -> Bool {
    let sensitive = ["token", "cookie", "password", "secret", "credential", "authorization", "csrf", "bearer"]
    let lower = key.lowercased()
    return sensitive.contains { lower.contains($0) }
  }

  private func nowString() -> String {
    isoFormatter.string(from: Date())
  }

  private func timestampForFilename() -> String {
    nowString()
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: ".", with: "-")
  }
}

enum DiagnosticsCrashCatcher {
  static func install() {
    NSSetUncaughtExceptionHandler(diagnosticsExceptionHandler)
    Darwin.signal(SIGABRT, diagnosticsSignalHandler)
    Darwin.signal(SIGILL, diagnosticsSignalHandler)
    Darwin.signal(SIGSEGV, diagnosticsSignalHandler)
    Darwin.signal(SIGFPE, diagnosticsSignalHandler)
    Darwin.signal(SIGBUS, diagnosticsSignalHandler)
    Darwin.signal(SIGPIPE, diagnosticsSignalHandler)
  }

  fileprivate static func storeCrash(_ reason: String) {
    UserDefaults.standard.set(reason, forKey: "diagnostics.lastCrashReason")
    UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: "diagnostics.lastCrashAt")
    UserDefaults.standard.set(true, forKey: "diagnostics.sessionDirty")
  }
}

private func diagnosticsExceptionHandler(_ exception: NSException) {
  DiagnosticsCrashCatcher.storeCrash("Uncaught exception: \(exception.name.rawValue) \(exception.reason ?? "")")
}

private func diagnosticsSignalHandler(_ signal: Int32) {
  DiagnosticsCrashCatcher.storeCrash("Fatal signal: \(signal)")
  Darwin.signal(signal, SIG_DFL)
  Darwin.raise(signal)
}

struct DiagnosticScreenModifier: ViewModifier {
  let name: String

  func body(content: Content) -> some View {
    content
      .onAppear {
        AppDiagnostics.shared.breadcrumb("Screen appeared", metadata: ["screen": name])
      }
      .onDisappear {
        AppDiagnostics.shared.breadcrumb("Screen disappeared", metadata: ["screen": name])
      }
  }
}

extension View {
  func diagnosticScreen(_ name: String) -> some View {
    modifier(DiagnosticScreenModifier(name: name))
  }

  func diagnosticLayout(_ name: String, metadata: [String: String] = [:]) -> some View {
    modifier(DiagnosticLayoutModifier(name: name, metadata: metadata))
  }
}

struct DiagnosticLayoutModifier: ViewModifier {
  let name: String
  let metadata: [String: String]
  @State private var lastLoggedSize: CGSize = .zero

  func body(content: Content) -> some View {
    content.background(
      GeometryReader { proxy in
        Color.clear
          .onAppear {
            logIfSuspicious(proxy.size)
          }
          .onChange(of: proxy.size) { _, size in
            logIfSuspicious(size)
          }
      }
    )
  }

  private func logIfSuspicious(_ size: CGSize) {
    guard isSuspicious(size), size != lastLoggedSize else { return }
    lastLoggedSize = size
    var merged = metadata
    merged["view"] = name
    merged["layoutSize"] = "\(size.width)x\(size.height)"
    AppDiagnostics.asyncRecord(
      .warning,
      category: "ui.layout",
      message: "Suspicious SwiftUI layout size",
      metadata: merged
    )
  }

  private func isSuspicious(_ size: CGSize) -> Bool {
    size.width.isNaN || size.height.isNaN || size.width <= 0 || size.height <= 0 || size.width > 5_000 || size.height > 5_000
  }
}
