//
//  CommentBodyNative.swift
//  winston
//
//  Renders a comment body for the native comments rebuild. Text runs go through
//  MarkdownUI; inline images / videos / direct-media links are extracted and
//  rendered with MediaPresenter, which provides tap-to-fullscreen (the lightbox
//  the legacy comment body had). Media is height-capped so a single image can't
//  dominate the viewport.
//
//  Width is passed in (derived from screen width minus insets and indent) rather
//  than measured with a GeometryReader, so media reserves its correct height on
//  the FIRST layout pass — no pop-in / scroll-jump when images finish loading.
//
//  The text/media split logic is ported from the legacy CommentLinkContent's
//  private CommentBodyView so behavior matches the old path.
//

import SwiftUI
import MarkdownUI
import Nuke
import Defaults

private enum CommentBodyPart: Identifiable, Equatable {
  case text(String)
  case media(URL)

  var id: String {
    switch self {
    case .text(let value): return "text-\(value.hashValue)"
    case .media(let url): return "media-\(url.absoluteString)"
    }
  }
}

struct CommentBodyNative: View {
  let markdown: String
  let availableWidth: CGFloat
  let fontSize: CGFloat
  let lineSpacing: CGFloat
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  let cornerRadius: Double
  let maxMediaHeightScreenPercentage: CGFloat
  let diagnosticContext: String
  var onTextTap: (() -> Void)? = nil

  @State private var showSpoiler = false
  @State private var postDimensions = PostDimensions.zero

  var body: some View {
    let _ = ScrollPerfDiagnostics.bump("commentBody.body")
    let sourceMarkdown = ScrollPerfDiagnostics.measure("commentBody.spoilerProcess", slowThresholdMs: 3, slowMessage: "Comment spoiler preprocessing was slow") {
      Self.spoilerProcessedMarkdown(markdown, showSpoiler: showSpoiler)
    }
    let parts = ScrollPerfDiagnostics.measure("commentBody.parts", slowThresholdMs: 4, slowMessage: "Comment text/media split was slow", metadata: ["context": diagnosticContext, "chars": "\(sourceMarkdown.count)"]) {
      Self.parts(from: sourceMarkdown)
    }

    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .text(let text):
          tappableMarkdownText(text)
        case .media(let url):
          if availableWidth >= 1 {
            let media = ScrollPerfDiagnostics.measure("commentBody.mediaExtractor", slowThresholdMs: 4, slowMessage: "Comment inline media extraction was slow", metadata: ["context": diagnosticContext, "urlHost": url.host ?? "nil"]) {
              mediaExtractor(url: url, compact: false, contentWidth: availableWidth, diagnosticContext: diagnosticContext)
            }
            if let media {
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
                contentWidth: availableWidth,
                maxMediaHeightScreenPercentage: maxMediaHeightScreenPercentage,
                resetVideo: { _ in },
                diagnosticContext: diagnosticContext
              )
              .contentShape(Rectangle())
              .diagnosticTapTarget("comment media", color: .purple)
            }
          }
        }
      }

      if MarkdownUtil.containsSpoiler(markdown) {
        Button {
          withAnimation { showSpoiler.toggle() }
        } label: {
          Label(showSpoiler ? "Hide spoiler" : "Show spoiler", systemImage: showSpoiler ? "eye.slash.fill" : "eye.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func markdownText(_ text: String) -> some View {
    ScrollPerfDiagnostics.bump("commentBody.markdownText")
    return Markdown(MarkdownUtil.formatForMarkdown(text, showSpoiler: showSpoiler))
      .markdownTheme(.winstonMarkdown(fontSize: fontSize, lineSpacing: lineSpacing))
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func tappableMarkdownText(_ text: String) -> some View {
    if let onTextTap {
      markdownText(text)
        .overlay {
          Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTextTap)
            .diagnosticTapTarget("comment text collapse", color: .orange)
        }
    } else {
      markdownText(text)
    }
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

  // MARK: - Text / media split (ported from legacy CommentBodyView)

  private static func parts(from markdown: String) -> [CommentBodyPart] {
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
    regexMatches(pattern: "!\\[([^\\]]*)\\]\\((https?://[^\\s)]+)\\)", in: text).compactMap {
      mediaMatch(match: $0, text: text, urlGroup: 2, labelGroup: nil)
    }
  }

  private static func markdownLinkMatches(in text: String) -> [MediaMatch] {
    regexMatches(pattern: "(?<!!)\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)", in: text).compactMap {
      mediaMatch(match: $0, text: text, urlGroup: 2, labelGroup: 1)
    }
  }

  private static func bareURLMatches(in text: String) -> [MediaMatch] {
    regexMatches(pattern: "(?<!\\]\\()\\bhttps?://[^\\s<>)]+", in: text).compactMap {
      mediaMatch(match: $0, text: text, urlGroup: 0, labelGroup: nil, trimTrailingPunctuation: true)
    }
  }

  private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
    ScrollPerfDiagnostics.bump("commentBody.regex")
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

struct NativeCommentPreview: View {
  @ObservedObject var comment: Comment
  var compact = false
  var availableWidth: CGFloat? = nil

  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Environment(\.auroraTheme) private var theme
  @Environment(\.contentWidth) private var contentWidth

  private var bodyWidth: CGFloat {
    max(1, (availableWidth ?? contentWidth) - 32)
  }

  var body: some View {
    if let data = comment.data {
      VStack(alignment: .leading, spacing: compact ? 4 : 8) {
        header(data)

        if let body = data.body, !body.isEmpty {
          CommentBodyNative(
            markdown: body,
            availableWidth: bodyWidth,
            fontSize: compact ? 14 : 15,
            lineSpacing: compact ? 1 : 2,
            postTitle: data.link_title ?? "",
            badgeKit: data.badgeKit,
            avatarImageRequest: comment.winstonData?.avatarImageRequest,
            cornerRadius: 10,
            maxMediaHeightScreenPercentage: min(postLinkDefSettings.maxMediaHeightScreenPercentage, compact ? 35 : 45),
            diagnosticContext: "commentPreview:\(comment.id)"
          )
          .frame(maxHeight: compact ? 46 : nil, alignment: .top)
          .clipped()
        }
      }
      .padding(compact ? 10 : 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: compact ? 12 : theme.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: compact ? 12 : theme.cornerRadius, style: .continuous)
          .stroke(theme.hairline, lineWidth: 0.7)
      )
    }
  }

  private func header(_ data: CommentData) -> some View {
    let author = displayAuthor(data)
    return HStack(spacing: 7) {
      AuroraAvatar(name: author, avatarRequest: comment.winstonData?.avatarImageRequest, size: compact ? 18 : 22)
      Text(author)
        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .lineLimit(1)
      if let subreddit = data.subreddit, !subreddit.isEmpty {
        Text("r/\(subreddit)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if let ups = data.ups {
        Label(formatBigNumber(ups), systemImage: "arrow.up")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func displayAuthor(_ data: CommentData) -> String {
    if let author = data.author, !author.isEmpty { return author }
    return "[deleted]"
  }
}
