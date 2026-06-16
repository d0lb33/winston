//
//  CommentLinkContent.swift
//  winston
//
//  Created by Igor Marcossi on 08/07/23.
//

import SwiftUI
import Defaults
import SwiftUIIntrospect
import MarkdownUI
import Nuke

private enum CommentBodyPart: Identifiable, Equatable {
  case text(String)
  case media(URL)

  var id: String {
    switch self {
    case .text(let value):
      return "text-\(value.hashValue)"
    case .media(let url):
      return "media-\(url.absoluteString)"
    }
  }
}

private struct CommentBodyView: View {
  let markdown: String
  let showSpoiler: Bool
  let selectable: Bool
  let fontSize: CGFloat
  let lineSpacing: CGFloat
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let cornerRadius: Double
  let maxMediaHeightScreenPercentage: CGFloat
  let diagnosticContext: String
  let forcedPreview: Bool

  @State private var postDimensions = PostDimensions.zero
  // Starts at 0 so media waits for the row's real width; seeding this with
  // the screen width let images render wider than the indented row and lock
  // the geometry feedback loop at full width.
  @State private var contentWidth: CGFloat = 0

  var body: some View {
    let sourceMarkdown = CommentBodyView.spoilerProcessedMarkdown(markdown, showSpoiler: showSpoiler)
    let parts = CommentBodyView.parts(from: sourceMarkdown, extractsMedia: !forcedPreview)

    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .text(let text):
          markdownText(text)
        case .media(let url):
          if contentWidth >= 1, let media = mediaExtractor(url: url, compact: false, contentWidth: contentWidth, diagnosticContext: diagnosticContext) {
            MediaPresenter(
              postDimensions: $postDimensions,
              controller: nil,
              postTitle: postTitle,
              badgeKit: badgeKit,
              avatarImageRequest: avatarImageRequest,
              markAsSeen: nil,
              cornerRadius: cornerRadius,
              blurPostLinkNSFW: false,
              media: media,
              compact: false,
              contentWidth: contentWidth,
              maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage,
              resetVideo: { _ in },
              diagnosticContext: diagnosticContext
            )
            .contentShape(Rectangle())
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { contentWidth = max(1, geo.size.width) }
          .onChange(of: geo.size) { _, size in contentWidth = max(1, size.width) }
      }
    )
  }

  private func markdownText(_ text: String) -> some View {
    Markdown(MarkdownUtil.formatForMarkdown(text, showSpoiler: showSpoiler))
      .markdownTheme(.winstonMarkdown(fontSize: fontSize, lineSpacing: lineSpacing, textSelection: selectable))
      .fixedSize(horizontal: false, vertical: true)
  }

  private static func spoilerProcessedMarkdown(_ text: String, showSpoiler: Bool) -> String {
    guard MarkdownUtil.containsSpoiler(text) else { return text }
    if showSpoiler {
      return text
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: ">!", with: "")
        .replacingOccurrences(of: "!<", with: "")
    }
    return MarkdownUtil.formatForMarkdown(text, showSpoiler: false)
  }

  private static func parts(from markdown: String, extractsMedia: Bool) -> [CommentBodyPart] {
    guard extractsMedia else { return [.text(markdown)] }

    var mediaMatches = markdownImageMatches(in: markdown) + markdownLinkMatches(in: markdown) + bareURLMatches(in: markdown)
    mediaMatches.sort { $0.range.location < $1.range.location }

    var parts: [CommentBodyPart] = []
    var currentLocation = 0
    var consumedRanges: [NSRange] = []

    for match in mediaMatches {
      guard match.range.location >= currentLocation else { continue }
      guard !consumedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }

      appendText(from: markdown, range: NSRange(location: currentLocation, length: match.range.location - currentLocation), to: &parts)

      if let label = match.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        appendText(label, to: &parts)
      }

      parts.append(.media(match.url))
      consumedRanges.append(match.range)
      currentLocation = match.range.location + match.range.length
    }

    appendText(from: markdown, range: NSRange(location: currentLocation, length: markdown.utf16.count - currentLocation), to: &parts)
    return parts.isEmpty ? [.text(markdown)] : parts
  }

  private struct MediaMatch {
    let range: NSRange
    let url: URL
    let label: String?
  }

  private static func markdownImageMatches(in text: String) -> [MediaMatch] {
    regexMatches(pattern: "!\\[([^\\]]*)\\]\\((https?://[^\\s)]+)\\)", in: text).compactMap { match in
      mediaMatch(match: match, text: text, urlGroup: 2, labelGroup: nil)
    }
  }

  private static func markdownLinkMatches(in text: String) -> [MediaMatch] {
    regexMatches(pattern: "(?<!!)\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)", in: text).compactMap { match in
      mediaMatch(match: match, text: text, urlGroup: 2, labelGroup: 1)
    }
  }

  private static func bareURLMatches(in text: String) -> [MediaMatch] {
    regexMatches(pattern: "(?<!\\]\\()\\bhttps?://[^\\s<>)]+", in: text).compactMap { match in
      mediaMatch(match: match, text: text, urlGroup: 0, labelGroup: nil, trimTrailingPunctuation: true)
    }
  }

  private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
  }

  private static func mediaMatch(match: NSTextCheckingResult, text: String, urlGroup: Int, labelGroup: Int?, trimTrailingPunctuation: Bool = false) -> MediaMatch? {
    let urlRange = match.range(at: urlGroup)
    guard let rawURL = string(in: text, range: urlRange) else { return nil }
    let normalized = normalizedMediaURL(from: rawURL, trimTrailingPunctuation: trimTrailingPunctuation)
    guard let url = normalized.url, isDirectMediaURL(url) else { return nil }

    let label = labelGroup.flatMap { string(in: text, range: match.range(at: $0)) }
    let range = trimTrailingPunctuation && normalized.removedUTF16Count > 0
      ? NSRange(location: match.range.location, length: match.range.length - normalized.removedUTF16Count)
      : match.range
    return MediaMatch(range: range, url: url, label: label)
  }

  private static func normalizedMediaURL(from rawURL: String, trimTrailingPunctuation: Bool) -> (url: URL?, removedUTF16Count: Int) {
    var urlString = rawURL.escape
    var removedUTF16Count = 0
    let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    if trimTrailingPunctuation {
      while let scalar = urlString.unicodeScalars.last, trailingPunctuation.contains(scalar) {
        urlString.removeLast()
        removedUTF16Count += String(scalar).utf16.count
      }
    }

    guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased()) else {
      return (nil, removedUTF16Count)
    }
    return (url, removedUTF16Count)
  }

  private static func string(in text: String, range: NSRange) -> String? {
    guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
    return String(text[swiftRange])
  }

  private static func appendText(from source: String, range: NSRange, to parts: inout [CommentBodyPart]) {
    guard let text = string(in: source, range: range) else { return }
    appendText(text, to: &parts)
  }

  private static func appendText(_ text: String, to parts: inout [CommentBodyPart]) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    parts.append(.text(text))
  }
}

class Sizer: ObservableObject {
  @Published var size: CGSize = .zero
}

struct CommentLinkContentPreview: View {
  @ObservedObject var sizer: Sizer
  var forcedBodySize: CGSize?
  var showReplies = true
  var arrowKinds: [ArrowKind]
  var indentLines: Int? = nil
  var lineLimit: Int?
  var post: Post?
  var comment: Comment
  var avatarsURL: [String:String]?
  @Environment(\.contentWidth) private var contentWidth

  var body: some View {
    if let data = comment.data, let winstonData = comment.winstonData {
      VStack(alignment: .leading, spacing: 0) {
        CommentLinkContent(forcedBodySize: sizer.size, showReplies: showReplies, arrowKinds: arrowKinds, indentLines: indentLines, lineLimit: lineLimit, post: post, comment: comment, winstonData: winstonData, avatarsURL: avatarsURL)
      }
      .frame(width: contentWidth, height: sizer.size.height + CGFloat((data.depth != 0 ? 42 : 30) + 16))
    }
  }
}

struct CommentLinkContent: View {
  static let indentLineContentSpacing: Double = 4
  static let indentLinesSpacing: Double = 6
  
  var disableBG = false
  var highlightID: String?
  var seenComments: String?
  var forcedBodySize: CGSize?
  var showReplies = true
  var arrowKinds: [ArrowKind]
  var indentLines: Int? = nil
  var lineLimit: Int?
  var post: Post?
  @ObservedObject var comment: Comment
  @ObservedObject var winstonData: CommentWinstonData
  var avatarsURL: [String:String]?

  @State private var sizer = Sizer()
  @State private var showReplyModal = false
  @State private var bodySize: CGSize = .zero
  @State private var highlight = false
  @State private var showSpoiler = false
  @State private var swipeActionsPresented = false
  @State private var loggedBodyDiagnostics = false
  
  @Default(.CommentLinkDefSettings) private var defSettings
  @Default(.CommentsSectionDefSettings) private var sectionDefSettings
  
  @Environment(\.useTheme) private var selectedTheme
  
  @State private var commentViewLoaded = false
  
  nonisolated func haptic() {
    Task(priority: .background) {
      let medium = await UIImpactFeedbackGenerator(style: .medium)
      await medium.prepare()
      await medium.impactOccurred()
    }
  }
  
  var body: some View {
    #if DEBUG
    let _ = RenderDiagnostics.logIfEnabled { Self._printChanges() }
    #endif
    let theme = selectedTheme.comments
    let selectable = (comment.data?.winstonSelecting ?? false)
    let horPad = theme.theme.innerPadding.horizontal
    
    
    if let data = comment.data {
      let collapsed = data.collapsed ?? false
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: CommentLinkContent.indentLineContentSpacing) {
          if data.depth != 0 && indentLines != 0 {
            HStack(alignment:. bottom, spacing: CommentLinkContent.indentLinesSpacing) {
              let shapes = Array(1...Int(indentLines ?? data.depth ?? 1))
              ForEach(shapes, id: \.self) { i in
                if arrowKinds.indices.contains(i - 1) {
                  let actualArrowKind = arrowKinds[i - 1]
                  Arrows(kind: actualArrowKind, offset: theme.theme.innerPadding.vertical + theme.theme.repliesSpacing)
                }
              }
            }
          }
          HStack(spacing: 8) {
            if let author = data.author {
              BadgeView(avatarRequest: winstonData.avatarImageRequest, saved: data.badgeKit.saved, unseen: seenComments == nil ? false : !seenComments!.contains(data.id), usernameColor: (post?.data?.author ?? "") == author ? Color.green : nil, author: data.badgeKit.author,fullname: data.badgeKit.authorFullname, userFlair: data.badgeKit.userFlair, created: data.badgeKit.created, theme: theme.theme.badge, commentTheme: theme.theme)
            }
            
            Spacer()
            
            if (data.saved ?? false) {
              Image(systemName: "bookmark.fill")
                .fontSize(14)
                .foregroundColor(.green)
                .transition(.scale.combined(with: .opacity))
            }
            
            if selectable {
              HStack(spacing: 2) {
                Circle()
                  .fill(.white)
                  .frame(width: 8, height: 8)
                Text("SELECTING")
              }
              .fontSize(13, .medium)
              .foregroundColor(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(.orange, in: Capsule(style: .continuous))
              .onTapGesture { withAnimation { comment.data?.winstonSelecting = false } }
            }
            
            if let ups = data.ups {
              HStack(alignment: .center, spacing: 4) {
                Image(systemName: "arrow.up")
                  .foregroundColor(data.likes != nil && data.likes! ? .orange : .gray)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    
                    Task {
                      haptic()
                      _ = await comment.vote(action: .up)
                    }
                  }
                
                let downup = Int(ups)
                Text(data.score_hidden == true ? "-" : formatBigNumber(downup))
                  .foregroundColor(data.likes != nil ? (data.likes! ? .orange : .blue) : .gray)
                  .contentTransition(.numericText())
                
                //                  .foregroundColor(downup == 0 ? .gray : downup > 0 ? .orange : .blue)
                  .fontSize(14, .semibold)
                
                Image(systemName: "arrow.down")
                  .foregroundColor(data.likes != nil && !data.likes! ? .blue : .gray)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    
                    Task {
                      haptic()
                      _ = await comment.vote(action: .down)
                    }
                  }
              }
              .fontSize(14, .medium)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule(style: .continuous).fill(.secondary.opacity(0.1)))
              //              .viewVotes(ups, downs)
              .allowsHitTesting(!collapsed)
              .scaleEffect(1)
              
              if collapsed {
                Image(systemName: "eye.slash.fill")
                  .fontSize(14, .medium)
                  .opacity(0.5)
                  .allowsHitTesting(false)
              }
              
            }
          }
          .padding(.top, max(0, theme.theme.innerPadding.vertical + (data.depth == 0 ? -theme.theme.cornerRadius : theme.theme.repliesSpacing)))
          .compositingGroup()
          .opacity(collapsed ? 0.5 : 1)
          .contentShape(Rectangle())
          .onTapGesture {
            guard !swipeActionsPresented else { return }
            withAnimation(spring) { comment.toggleCollapsed(optimistic: true) }
          }
        }
        .padding(.horizontal, horPad)
        .frame(height: max(((theme.theme.badge.authorText.size * 1.2) + (theme.theme.badge.statsText.size * 1.2) + 2), theme.theme.badge.avatar.size) + max(0, theme.theme.innerPadding.vertical + (data.depth == 0 ? -theme.theme.cornerRadius : theme.theme.repliesSpacing)), alignment: .leading)
        .mask(Color.black)
        .onAppear {
          if !commentViewLoaded && sectionDefSettings.collapseAutoModerator {
            if data.depth == 0 && data.author == "AutoModerator" && !(data.collapsed ?? false) {
              comment.toggleCollapsed(optimistic: true)
            }
          } else {
            commentViewLoaded = true
          }
        }
        .id("\(data.id)-header\(forcedBodySize == nil ? "" : "-preview")")
        
        if !collapsed {
          HStack(spacing: CommentLinkContent.indentLineContentSpacing) {
            if data.depth != 0 && indentLines != 0 {
              HStack(alignment:. bottom, spacing: CommentLinkContent.indentLinesSpacing) {
                let shapes = Array(1...Int(indentLines ?? data.depth ?? 1))
                ForEach(shapes, id: \.self) { i in
                  if arrowKinds.indices.contains(i - 1) {
                    let actualArrowKind = arrowKinds[i - 1]
                    Arrows(kind: actualArrowKind.child)
                  }
                }
              }
              .mask(Rectangle())
            }
            if let body = data.body {
              VStack {
                Group {
                  if lineLimit != nil {
                    Text(body.md())
                      .lineLimit(lineLimit)
                  } else {
                    HStack {
                      CommentBodyView(
                        markdown: body,
                        showSpoiler: showSpoiler,
                        selectable: selectable,
                        fontSize: theme.theme.bodyText.size,
                        lineSpacing: theme.theme.linespacing,
                        postTitle: post?.data?.title ?? data.link_title ?? "",
                        badgeKit: data.badgeKit,
                        avatarImageRequest: winstonData.avatarImageRequest,
                        cornerRadius: theme.theme.cornerRadius,
                        maxMediaHeightScreenPercentage: Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage,
                        diagnosticContext: "comment:\(data.id):\(String(body.prefix(80)))",
                        forcedPreview: forcedBodySize != nil
                      )
                      
                      if MarkdownUtil.containsSpoiler(body) {
                        Spacer()
                        Image(systemName: showSpoiler ? "eye.slash.fill" : "eye.fill")
                          .onTapGesture {
                            withAnimation {
                              showSpoiler = !showSpoiler
                            }
                          }
                      }
                    }
                  }
                }
                .fontSize(theme.theme.bodyText.size, theme.theme.bodyText.weight.t)
                .foregroundColor(theme.theme.bodyText.color())
              }
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(.top, theme.theme.bodyAuthorSpacing)
              .padding(.bottom, max(0, theme.theme.innerPadding.vertical + (data.depth == 0 && comment.childrenWinston.data.count == 0 ? -theme.theme.cornerRadius : theme.theme.innerPadding.vertical)))
              .scaleEffect(1)
              .contentShape(Rectangle())
              .onTapGesture {
                guard !selectable, !swipeActionsPresented else { return }
                withAnimation(spring) { comment.toggleCollapsed(optimistic: true) }
              }
              .background(forcedBodySize != nil ? nil : GeometryReader { geo in Color.clear.onAppear {
                sizer.size = geo.size
                bodySize = geo.size
              } } )
            } else {
              Spacer()
            }
          }
          .padding(.horizontal, horPad)
          .mask(Color.black.padding(.top, -(data.depth != 0 ? 42 : 30)).padding(.bottom, -8))
          .id("\(data.id)-body\(forcedBodySize == nil ? "" : "-preview")")
        }
      }
      .background(Color.accentColor.opacity(highlight ? 0.2 : 0))
      .background(showReplies ? theme.theme.bg() : .clear)
      .commentSwipeActions(
        comment: comment,
        actionsSet: defSettings.swipeActions,
        enabled: forcedBodySize == nil,
        actionsArePresented: $swipeActionsPresented
      )
      .onAppear {
        if !loggedBodyDiagnostics && data.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
          loggedBodyDiagnostics = true
          AppDiagnostics.asyncRecord(
            .warning,
            category: "ui.commentRow",
            message: "Visible comment row has no body",
            metadata: [
              "id": data.id,
              "name": data.name ?? "nil",
              "parent": data.parent_id ?? "nil",
              "post": data.link_id ?? post?.data?.name ?? "nil",
              "author": data.author ?? "nil",
              "depth": "\(data.depth ?? -1)",
              "hasHTML": "\(data.body_html?.isEmpty == false)"
            ]
          )
        }
        if var specificID = highlightID {
          specificID = specificID.hasPrefix("t1_") ? String(specificID.dropFirst(3)) : specificID
          if specificID == data.id { withAnimation { highlight = true } }
          doThisAfter(0.1) {
            withAnimation(.easeOut(duration: 4)) { highlight = false }
          }
        }
      }
      .contextMenu {
        if !selectable && forcedBodySize == nil {
          ForEach(allCommentSwipeActions) { action in
            let active = action.active(comment)
            if action.enabled(comment) {
              Button {
                Task(priority: .background) {
                  await action.action(comment)
                }
              } label: {
                Label(active ? "Undo \(action.label.lowercased())" : action.label, systemImage: active ? action.icon.active : action.icon.normal)
                  .foregroundColor(action.bgColor.normal == "353439" ? action.color.normal == "FFFFFF" ? Color.blue : Color.hex(action.color.normal) : Color.hex(action.bgColor.normal))
              }
            }
          }
          
          if let permalink = data.permalink, let permaURL = URL(string: "https://reddit.com\(permalink.escape.urlEncoded)") {
            ShareLink(item: permaURL) { Label("Share", systemImage: "square.and.arrow.up") }
          }

          Divider()
          Button {
            let layout = RenderingReportLayoutContext(
              surface: "comment-context-menu",
              renderer: "legacy-comment",
              rowSize: sizer.size == .zero ? nil : "\(sizer.size.width)x\(sizer.size.height)",
              bodySize: bodySize == .zero ? nil : "\(bodySize.width)x\(bodySize.height)",
              postDimensions: nil,
              forcedPostDimensions: nil,
              collapsed: data.collapsed,
              depth: data.depth
            )
            RenderingReportStore.shared.captureCommentIssue(
              comment: comment,
              surface: "comment-context-menu",
              treeContext: [
                "treePosition": data.parent_id?.hasPrefix("t1_") == true ? "nested" : "top-level"
              ],
              layout: layout
            )
          } label: {
            Label("Report Rendering Issue", systemImage: "exclamationmark.bubble")
          }
          
        }
      } preview: {
        CommentLinkContentPreview(sizer: sizer, forcedBodySize: sizer.size, showReplies: showReplies, arrowKinds: arrowKinds, indentLines: indentLines, lineLimit: lineLimit, post: post, comment: comment, avatarsURL: avatarsURL)
          .id("\(data.id)-preview")
      }
    } else {
      Text("oops")
    }
  }
}

//struct CommentLinkContent_Previews: PreviewProvider {
//    static var previews: some View {
//        CommentLinkContent()
//    }
//}

struct AnimatingCellHeight: AnimatableModifier {
  var height: CGFloat = 0
  var disable: Bool = false
  
  var animatableData: CGFloat {
    get { height }
    set { height = newValue }
  }
  
  func body(content: Content) -> some View {
    content.frame(height: disable ? nil : height, alignment: .topLeading)
  }
}
