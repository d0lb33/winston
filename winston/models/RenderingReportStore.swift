//
//  RenderingReportStore.swift
//  winston
//
//  Local rendering issue reports bundled with diagnostics exports.
//

import Foundation
import UIKit
import Defaults

enum RenderingReportSubjectKind: String, Codable {
  case post
  case comment
}

struct RenderingReportLayoutContext: Codable, Hashable {
  var surface: String
  var renderer: String?
  var rowSize: String?
  var bodySize: String?
  var postDimensions: String?
  var forcedPostDimensions: String?
  var collapsed: Bool?
  var depth: Int?
}

struct RenderingReportMediaContext: Codable, Hashable {
  var postDataSummary: String?
  var extractedMedia: String?
  var forcedExtractedMedia: String?
  var maxMediaHeightScreenPercentage: Double
  var blurNSFW: Bool
  var effectivePostStyle: String
}

struct RenderingReportAppContext: Codable, Hashable {
  var appVersion: String
  var appBuild: String
  var bundleID: String
  var selectedTab: String
  var selectedThemeID: String
  var screen: String
  var safeAreaInsets: String
  var systemName: String
  var systemVersion: String
  var locale: String
  var timeZone: String
}

enum RenderingReportSubject: Codable {
  case post(RenderingReportPostSubject)
  case comment(RenderingReportCommentSubject)

  enum CodingKeys: String, CodingKey {
    case kind
    case post
    case comment
  }

  var kind: RenderingReportSubjectKind {
    switch self {
    case .post: return .post
    case .comment: return .comment
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(RenderingReportSubjectKind.self, forKey: .kind)
    switch kind {
    case .post:
      self = .post(try container.decode(RenderingReportPostSubject.self, forKey: .post))
    case .comment:
      self = .comment(try container.decode(RenderingReportCommentSubject.self, forKey: .comment))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .post(let value):
      try container.encode(value, forKey: .post)
    case .comment(let value):
      try container.encode(value, forKey: .comment)
    }
  }
}

struct RenderingReportPostSubject: Codable {
  var id: String
  var fullname: String
  var subreddit: String
  var author: String
  var title: String
  var permalink: String
  var url: String
  var postHint: String?
  var isVideo: Bool?
  var isGallery: Bool?
  var over18: Bool?
  var data: [String: DiagnosticJSONValue]
}

struct RenderingReportCommentSubject: Codable {
  var id: String
  var fullname: String?
  var postFullname: String?
  var parentFullname: String?
  var subreddit: String?
  var author: String?
  var permalink: String?
  var depth: Int?
  var collapsed: Bool?
  var childCount: Int
  var siblingIndex: Int?
  var treePosition: String
  var bodyLength: Int
  var htmlLength: Int
  var data: [String: DiagnosticJSONValue]
}

struct RenderingReport: Codable, Identifiable {
  var id: UUID
  var capturedAt: String
  var sessionID: String
  var subject: RenderingReportSubject
  var layout: RenderingReportLayoutContext
  var media: RenderingReportMediaContext?
  var app: RenderingReportAppContext
  var recentEvents: [DiagnosticEntry]
  var screenshotFilename: String?
}

struct RenderingReportIndexItem: Codable, Identifiable {
  var id: UUID
  var capturedAt: String
  var kind: RenderingReportSubjectKind
  var title: String
  var reportFilename: String
  var screenshotFilename: String?
}

enum DiagnosticJSONValue: Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: DiagnosticJSONValue])
  case array([DiagnosticJSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let object = try? container.decode([String: DiagnosticJSONValue].self) {
      self = .object(object)
    } else if let array = try? container.decode([DiagnosticJSONValue].self) {
      self = .array(array)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

@MainActor
final class RenderingReportStore: ObservableObject {
  static let shared = RenderingReportStore()

  @Published private(set) var reportCount: Int = 0
  @Published private(set) var lastCaptureMessage: String?

  private let isoFormatter = ISO8601DateFormatter()
  private var lastCaptureMessageID: UUID?
  private let maxReports = 50
  private let maxBytes = 25_000_000
  private let maxStringLength = 20_000
  private let maxArrayItems = 80
  private let maxObjectEntries = 120

  private var reportsDirectory: URL {
    AppDiagnostics.shared.logDirectory.appendingPathComponent("RenderingReports", isDirectory: true)
  }

  private init() {
    refreshReportCount()
  }

  func capturePostIssue(
    post: Post,
    surface: String,
    layout: RenderingReportLayoutContext? = nil,
    screenshotProvider: @MainActor () -> UIImage? = { RenderingReportStore.captureActiveWindowScreenshot() }
  ) {
    guard let data = post.data else {
      AppDiagnostics.shared.record(.warning, category: "diagnostics.renderingReport", message: "Post report skipped because post data is missing", metadata: ["post": post.id])
      return
    }

    let reportID = UUID()
    let screenshotFilename = writeScreenshot(screenshotProvider(), reportID: reportID)
    let settings = Defaults[.PostLinkDefSettings]
    let winstonData = post.winstonData
    let subject = RenderingReportSubject.post(
      RenderingReportPostSubject(
        id: data.id,
        fullname: data.name,
        subreddit: data.subreddit,
        author: data.author,
        title: clipped(data.title),
        permalink: clipped(data.permalink),
        url: clipped(data.url),
        postHint: data.post_hint,
        isVideo: data.is_video,
        isGallery: data.is_gallery,
        over18: data.over_18,
        data: sanitizedModel(data)
      )
    )
    var resolvedLayout = layout ?? RenderingReportLayoutContext(surface: surface, renderer: nil, rowSize: nil, bodySize: nil, postDimensions: nil, forcedPostDimensions: nil, collapsed: nil, depth: nil)
    resolvedLayout.surface = surface
    if resolvedLayout.renderer == nil {
      resolvedLayout.renderer = settings.effectivePostStyle.rawValue
    }
    if resolvedLayout.postDimensions == nil {
      resolvedLayout.postDimensions = describe(winstonData?.postDimensions)
    }
    if resolvedLayout.forcedPostDimensions == nil {
      resolvedLayout.forcedPostDimensions = describe(winstonData?.postDimensionsForcedNormal)
    }

    let report = RenderingReport(
      id: reportID,
      capturedAt: nowString(),
      sessionID: AppDiagnostics.shared.currentSessionID,
      subject: subject,
      layout: resolvedLayout,
      media: RenderingReportMediaContext(
        postDataSummary: Post.diagnosticsPostDataMedia(data),
        extractedMedia: Post.diagnosticsMediaKind(winstonData?.extractedMedia),
        forcedExtractedMedia: Post.diagnosticsMediaKind(winstonData?.extractedMediaForcedNormal),
        maxMediaHeightScreenPercentage: settings.maxMediaHeightScreenPercentage,
        blurNSFW: settings.blurNSFW,
        effectivePostStyle: settings.effectivePostStyle.rawValue
      ),
      app: makeAppContext(),
      recentEvents: Array(AppDiagnostics.shared.entries.suffix(100)),
      screenshotFilename: screenshotFilename
    )
    persist(report)
    showCaptureMessage("Rendering report saved")
    AppDiagnostics.shared.record(.info, category: "diagnostics.renderingReport", message: "Captured post rendering report", metadata: ["post": data.name, "surface": surface, "screenshot": screenshotFilename == nil ? "no" : "yes"])
  }

  func captureCommentIssue(
    comment: Comment,
    surface: String,
    treeContext: [String: String] = [:],
    layout: RenderingReportLayoutContext? = nil,
    screenshotProvider: @MainActor () -> UIImage? = { RenderingReportStore.captureActiveWindowScreenshot() }
  ) {
    guard let data = comment.data else {
      AppDiagnostics.shared.record(.warning, category: "diagnostics.renderingReport", message: "Comment report skipped because comment data is missing", metadata: ["comment": comment.id])
      return
    }

    let reportID = UUID()
    let screenshotFilename = writeScreenshot(screenshotProvider(), reportID: reportID)
    let body = data.body ?? ""
    let html = data.body_html ?? ""
    let childCount = comment.childrenWinston.data.count
    let siblingIndex = comment.parentWinston?.data.firstIndex(where: { $0.id == comment.id })
    let subject = RenderingReportSubject.comment(
      RenderingReportCommentSubject(
        id: data.id,
        fullname: data.name,
        postFullname: data.link_id,
        parentFullname: data.parent_id,
        subreddit: data.subreddit,
        author: data.author,
        permalink: data.permalink.map { clipped($0) },
        depth: data.depth,
        collapsed: data.collapsed,
        childCount: childCount,
        siblingIndex: siblingIndex,
        treePosition: treeContext["treePosition"] ?? describeCommentTreePosition(data),
        bodyLength: body.count,
        htmlLength: html.count,
        data: sanitizedModel(data)
      )
    )
    var resolvedLayout = layout ?? RenderingReportLayoutContext(surface: surface, renderer: "legacy-comment", rowSize: nil, bodySize: nil, postDimensions: nil, forcedPostDimensions: nil, collapsed: data.collapsed, depth: data.depth)
    resolvedLayout.surface = surface
    resolvedLayout.collapsed = data.collapsed
    resolvedLayout.depth = data.depth

    let report = RenderingReport(
      id: reportID,
      capturedAt: nowString(),
      sessionID: AppDiagnostics.shared.currentSessionID,
      subject: subject,
      layout: resolvedLayout,
      media: nil,
      app: makeAppContext(),
      recentEvents: Array(AppDiagnostics.shared.entries.suffix(100)),
      screenshotFilename: screenshotFilename
    )
    persist(report)
    showCaptureMessage("Rendering report saved")
    AppDiagnostics.shared.record(.info, category: "diagnostics.renderingReport", message: "Captured comment rendering report", metadata: ["comment": data.name ?? data.id, "surface": surface, "screenshot": screenshotFilename == nil ? "no" : "yes"])
  }

  func exportReports(to exportDirectory: URL) throws -> [URL] {
    refreshReportCount()
    guard reportCount > 0 else { return [] }

    let destination = exportDirectory.appendingPathComponent("rendering-reports", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    var exported: [URL] = []
    var index: [RenderingReportIndexItem] = []
    for reportURL in sortedReportFiles() {
      let reportDestination = destination.appendingPathComponent(reportURL.lastPathComponent)
      try FileManager.default.copyItem(at: reportURL, to: reportDestination)
      exported.append(reportDestination)

      guard
        let data = try? Data(contentsOf: reportURL),
        let report = try? JSONDecoder().decode(RenderingReport.self, from: data)
      else { continue }

      if let screenshotFilename = report.screenshotFilename {
        let screenshotURL = reportsDirectory.appendingPathComponent(screenshotFilename)
        if FileManager.default.fileExists(atPath: screenshotURL.path) {
          let screenshotDestination = destination.appendingPathComponent(screenshotFilename)
          try? FileManager.default.copyItem(at: screenshotURL, to: screenshotDestination)
          exported.append(screenshotDestination)
        }
      }

      index.append(
        RenderingReportIndexItem(
          id: report.id,
          capturedAt: report.capturedAt,
          kind: report.subject.kind,
          title: reportTitle(report),
          reportFilename: reportURL.lastPathComponent,
          screenshotFilename: report.screenshotFilename
        )
      )
    }

    let indexURL = destination.appendingPathComponent("rendering-reports-index.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(index).write(to: indexURL, options: .atomic)
    exported.append(indexURL)
    return exported
  }

  func clearReports() {
    try? FileManager.default.removeItem(at: reportsDirectory)
    refreshReportCount()
    AppDiagnostics.shared.record(.info, category: "diagnostics.renderingReport", message: "Cleared rendering reports")
  }

  func refreshReportCount() {
    reportCount = sortedReportFiles().count
  }

  private func persist(_ report: RenderingReport) {
    do {
      try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let url = reportsDirectory.appendingPathComponent("rendering-report-\(report.id.uuidString).json")
      try encoder.encode(report).write(to: url, options: .atomic)
      pruneReports()
      refreshReportCount()
    } catch {
      AppDiagnostics.shared.record(.error, category: "diagnostics.renderingReport", message: "Failed to save rendering report: \(error.localizedDescription)")
    }
  }

  private func writeScreenshot(_ image: UIImage?, reportID: UUID) -> String? {
    guard let image, let data = image.jpegData(compressionQuality: 0.78) else { return nil }
    do {
      try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
      let filename = "rendering-report-\(reportID.uuidString).jpg"
      try data.write(to: reportsDirectory.appendingPathComponent(filename), options: .atomic)
      return filename
    } catch {
      AppDiagnostics.shared.record(.warning, category: "diagnostics.renderingReport", message: "Failed to save rendering report screenshot: \(error.localizedDescription)")
      return nil
    }
  }

  private func sortedReportFiles() -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else { return [] }
    return contents
      .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("rendering-report-") }
      .sorted { lhs, rhs in
        let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return leftDate < rightDate
      }
  }

  private func pruneReports() {
    var reports = sortedReportFiles()
    while reports.count > maxReports {
      removeReportAndScreenshot(reportURL: reports.removeFirst())
    }

    while totalReportsSize() > maxBytes, let oldest = reports.first {
      removeReportAndScreenshot(reportURL: oldest)
      reports.removeFirst()
    }
  }

  private func removeReportAndScreenshot(reportURL: URL) {
    if
      let data = try? Data(contentsOf: reportURL),
      let report = try? JSONDecoder().decode(RenderingReport.self, from: data),
      let screenshotFilename = report.screenshotFilename {
      try? FileManager.default.removeItem(at: reportsDirectory.appendingPathComponent(screenshotFilename))
    }
    try? FileManager.default.removeItem(at: reportURL)
  }

  private func totalReportsSize() -> Int {
    guard let contents = try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return contents.reduce(0) { total, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return total + size
    }
  }

  private func sanitizedModel<T: Encodable>(_ value: T) -> [String: DiagnosticJSONValue] {
    let encoder = JSONEncoder()
    guard
      let data = try? encoder.encode(value),
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [:] }
    if case .object(let dict) = sanitizeJSONObject(object, key: nil) {
      return dict
    }
    return [:]
  }

  private func sanitizeJSONObject(_ value: Any, key: String?) -> DiagnosticJSONValue {
    if let key, isSensitiveKey(key) {
      return .string("<redacted>")
    }

    switch value {
    case let dict as [String: Any]:
      var output: [String: DiagnosticJSONValue] = [:]
      for (key, value) in dict.sorted(by: { $0.key < $1.key }).prefix(maxObjectEntries) {
        output[clipped(key, limit: 200)] = sanitizeJSONObject(value, key: key)
      }
      if dict.count > maxObjectEntries {
        output["_truncatedEntryCount"] = .number(Double(dict.count - maxObjectEntries))
      }
      return .object(output)
    case let array as [Any]:
      var output = array.prefix(maxArrayItems).map { sanitizeJSONObject($0, key: key) }
      if array.count > maxArrayItems {
        output.append(.object(["_truncatedItemCount": .number(Double(array.count - maxArrayItems))]))
      }
      return .array(output)
    case let string as String:
      return .string(clipped(string))
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      return .number(number.doubleValue)
    case _ as NSNull:
      return .null
    default:
      return .string(clipped(String(describing: value)))
    }
  }

  private func clipped(_ value: String, limit: Int? = nil) -> String {
    let maxLength = limit ?? maxStringLength
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength)) + "\n<truncated \(value.count - maxLength) chars>"
  }

  private func isSensitiveKey(_ key: String) -> Bool {
    let sensitive = ["token", "cookie", "password", "secret", "credential", "authorization", "csrf", "bearer", "session"]
    let lower = key.lowercased()
    return sensitive.contains { lower.contains($0) }
  }

  private func makeAppContext() -> RenderingReportAppContext {
    let bundle = Bundle.main
    return RenderingReportAppContext(
      appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      appBuild: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
      bundleID: bundle.bundleIdentifier ?? "unknown",
      selectedTab: Nav.shared.activeTab.rawValue,
      selectedThemeID: Defaults[.ThemesDefSettings].selectedThemeID,
      screen: "\(Int(ScreenMetrics.bounds.width))x\(Int(ScreenMetrics.bounds.height)) @\(ScreenMetrics.scale)x",
      safeAreaInsets: "\(ScreenMetrics.safeAreaInsets.top),\(ScreenMetrics.safeAreaInsets.left),\(ScreenMetrics.safeAreaInsets.bottom),\(ScreenMetrics.safeAreaInsets.right)",
      systemName: UIDevice.current.systemName,
      systemVersion: UIDevice.current.systemVersion,
      locale: Locale.current.identifier,
      timeZone: TimeZone.current.identifier
    )
  }

  private func reportTitle(_ report: RenderingReport) -> String {
    switch report.subject {
    case .post(let post):
      return post.title
    case .comment(let comment):
      return comment.permalink ?? comment.fullname ?? comment.id
    }
  }

  private func describeCommentTreePosition(_ data: CommentData) -> String {
    if data.parent_id?.hasPrefix("t1_") == true { return "nested" }
    if data.parent_id?.hasPrefix("t3_") == true || data.depth == 0 { return "top-level" }
    return "unknown"
  }

  private func describe(_ dimensions: PostDimensions?) -> String? {
    guard let dimensions else { return nil }
    return String(describing: dimensions)
  }

  private func nowString() -> String {
    isoFormatter.string(from: Date())
  }

  private func showCaptureMessage(_ message: String) {
    let messageID = UUID()
    lastCaptureMessageID = messageID
    lastCaptureMessage = message
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      if lastCaptureMessageID == messageID {
        lastCaptureMessage = nil
        lastCaptureMessageID = nil
      }
    }
  }

  static func captureActiveWindowScreenshot() -> UIImage? {
    guard
      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
      let window = scene.keyWindow ?? scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = window.screen.scale
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
    return renderer.image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
  }
}
