//
//  AuroraComponents.swift
//  winston
//
//  Aurora — shared Liquid Glass building blocks, driven by `AuroraTheme` from the
//  environment. These are the production components now wired to the real Reddit
//  entities (Post / Subreddit) and the production media pipeline (MediaPresenter via
//  PostRowMediaNative). The mock value types are gone.
//
//  PERFORMANCE: real `.glassEffect` (live blur) is reserved for a few *chrome*
//  elements (vote pills, sort bar, composer, close). Scrolling feed cards use a cheap
//  translucent fill — live-blur materials re-blurred against the animating mesh on
//  every scroll frame overwhelm the render server and hang the UI.
//

import SwiftUI
import Defaults
import NukeUI
import UIKit

// MARK: - Aurora app list primitives

enum AuroraPostPresentation {
  static let winstonTheme = defaultTheme
  static var mediaTheme: PostLinkTheme { winstonTheme.postLinks.theme }
  static var avatarSize: Double { 32 }
}

extension Post {
  func setupAuroraData(data: PostData? = nil, sub: Subreddit? = nil, contentWidth: Double = Double(defaultContentWidth), fetchAvatar: Bool = true) {
    setupWinstonData(data: data, contentWidth: contentWidth, theme: AuroraPostPresentation.winstonTheme, sub: sub, fetchAvatar: fetchAvatar)
  }
}

struct AuroraListChrome: ViewModifier {
  @Environment(\.auroraTheme) private var theme

  func body(content: Content) -> some View {
    content
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .tint(theme.accent)
      .fontDesign(theme.fontDesign)
      .background { AuroraBackdrop(theme: theme) }
  }
}

struct AuroraSettingsSectionModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listSectionSpacing(15)
  }
}

extension View {
  func auroraListChrome() -> some View {
    modifier(AuroraListChrome())
  }

  func auroraSettingsSection() -> some View {
    modifier(AuroraSettingsSectionModifier())
  }
}

struct AuroraRowButton<Label: View>: View {
  var showArrow = false
  var active = false
  var role: ButtonRole?
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @Environment(\.auroraTheme) private var theme
  @State private var forcedActive = false

  init(showArrow: Bool = false, active: Bool = false, role: ButtonRole? = nil, _ action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
    self.showArrow = showArrow
    self.active = active
    self.role = role
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(role: role) {
      forcedActive = true
      action()
      doThisAfter(0.45) {
        forcedActive = false
      }
    } label: {
      HStack(spacing: 12) {
        label()
          .frame(maxWidth: .infinity, alignment: .leading)

        if showArrow {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 14), style: .continuous))
    }
    .buttonStyle(.plain)
    .background(rowFill, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 14), style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: min(theme.cornerRadius, 14), style: .continuous)
        .stroke(rowStroke, lineWidth: 0.7)
    )
    .onAppear { forcedActive = false }
  }

  private var rowFill: Color {
    if forcedActive || active {
      return theme.accent.opacity(0.18)
    }
    return theme.cardFill
  }

  private var rowStroke: Color {
    active ? theme.accent.opacity(0.75) : theme.hairline
  }
}

struct AuroraActionRow: View {
  let title: LocalizedStringKey
  var systemImage: String?
  var active = false
  var role: ButtonRole?
  let action: () -> Void

  var body: some View {
    AuroraRowButton(active: active, role: role, action) {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
  }
}

struct AuroraNavigationRow<Label: View>: View {
  let value: NavDest
  var active = false
  @ViewBuilder let label: () -> Label

  @Environment(\.settingsNavigationModel) private var settingsNavigationModel
  @Environment(\.settingsNavigationOrigin) private var settingsNavigationOrigin
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  init(_ value: NavDest, active: Bool = false, @ViewBuilder label: @escaping () -> Label) {
    self.value = value
    self.active = active
    self.label = label
  }

  init(value: NavDest, active: Bool = false, @ViewBuilder label: @escaping () -> Label) {
    self.value = value
    self.active = active
    self.label = label
  }

  var body: some View {
    AuroraRowButton(showArrow: true, active: active) {
      AppDiagnostics.asyncBreadcrumb("AuroraNavigationRow tapped", metadata: ["destination": value.diagnosticsName])
      if navigateSettingsDestination(value, model: settingsNavigationModel, origin: settingsNavigationOrigin) {
        return
      }
      navigateRedditDestination(value, model: redditNavigationModel, origin: redditNavigationOrigin)
    } label: {
      label()
    }
  }
}

extension AuroraNavigationRow where Label == AnyView {
  init(_ value: NavDest, active: Bool = false, title: LocalizedStringKey, systemImage: String? = nil) {
    self.value = value
    self.active = active
    self.label = {
      if let systemImage {
        AnyView(SwiftUI.Label(title, systemImage: systemImage))
      } else {
        AnyView(Text(title))
      }
    }
  }
}

struct AuroraMetricTile: View {
  let icon: String
  let label: String
  let value: String
  var active = false
  var action: (() -> Void)?

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    let content = VStack(spacing: 5) {
      Image(systemName: icon)
        .font(.title3.weight(.semibold))
        .foregroundStyle(active ? theme.accent : theme.accent.opacity(0.85))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 86)
    .background(active ? theme.accent.opacity(0.16) : theme.cardFill, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous)
        .stroke(active ? theme.accent.opacity(0.7) : theme.hairline, lineWidth: 0.7)
    )

    if let action {
      Button(action: action) { content }
        .buttonStyle(.plain)
    } else {
      content
    }
  }
}

// MARK: - Offline palette (stable per-seed colors; no network, cheap under scroll)

enum AuroraPalette {
  static let colors: [Color] = [
    .indigo, .teal, .pink, Color(red: 1.0, green: 0.72, blue: 0.22),
    .green, .blue, .purple, .orange, .mint, .red,
  ]

  static func color(for seed: String) -> Color {
    var hash = 5381
    for byte in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
    return colors[abs(hash) % colors.count]
  }

  static func gradient(for seed: String) -> [Color] {
    let base = color(for: seed)
    return [base.opacity(0.95), base.opacity(0.6)]
  }
}

// MARK: - App backdrop

/// Background hook for Aurora surfaces. Kept neutral until Aurora background
/// treatment is wired consistently through the main app surfaces.
struct AuroraBackdrop: View {
  let theme: AuroraTheme

  var body: some View {
    Color(uiColor: .systemBackground)
      .ignoresSafeArea()
  }
}

// MARK: - Icons & avatars (offline monograms)

struct AuroraSubIcon: View {
  let name: String
  var iconKit: SubredditIconKit? = nil
  var size: CGFloat = 30
  private var letter: String { String((name.first { $0.isLetter || $0.isNumber } ?? "r")).uppercased() }
  var body: some View {
    if let urlString = iconKit?.url, let url = URL(string: urlString) {
      LazyImage(url: url) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          monogram
        }
      }
      .processors([.resize(width: size)])
      .frame(width: size, height: size)
      .clipShape(Circle())
    } else {
      monogram
    }
  }

  private var monogram: some View {
    Circle()
      .fill(LinearGradient(colors: AuroraPalette.gradient(for: name), startPoint: .topLeading, endPoint: .bottomTrailing))
      .frame(width: size, height: size)
      .overlay(
        Text(letter)
          .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
      )
  }
}

extension Subreddit {
  var needsAuroraMetadataRefresh: Bool {
    guard let data else { return true }
    let hasMembers = (data.subscribers ?? 0) > 0
    let hasIcon = data.subredditIconKit.url?.isEmpty == false
    return !hasMembers || !hasIcon
  }
}

struct AuroraAvatar: View {
  let name: String
  var avatarRequest: ImageRequest? = nil
  var size: CGFloat = 22
  private var letter: String { String((name.first { $0.isLetter || $0.isNumber } ?? "u")).uppercased() }
  var body: some View {
    Group {
      if let avatarRequest {
        ThumbReqImage(imgRequest: avatarRequest, size: CGSize(width: size, height: size))
      } else {
        monogram
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  private var monogram: some View {
    Circle()
      .fill(LinearGradient(colors: AuroraPalette.gradient(for: name), startPoint: .top, endPoint: .bottom))
      .overlay(
        Text(letter)
          .font(.system(size: size * 0.48, weight: .bold))
          .foregroundStyle(.white)
      )
  }
}

// MARK: - Flair

struct AuroraFlair: View {
  let text: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(theme.accent.opacity(0.22), in: .capsule)
      .foregroundStyle(theme.accent)
  }
}

// MARK: - Interactive glass vote pill (chrome — real glass is fine here)

struct GlassVotePill: View {
  let likes: Bool?
  let score: Int
  var compact: Bool = false
  let onUp: () async -> Void
  let onDown: () async -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: compact ? 8 : 11) {
      voteButton("arrow.up", active: likes == true, color: theme.accent) { Task { await onUp() } }
      Text(formatBigNumber(score))
        .font(.subheadline.weight(.semibold)).monospacedDigit()
        .foregroundStyle(likes == true ? theme.accent : likes == false ? theme.downvote : .primary)
        .contentTransition(.numericText())
      voteButton("arrow.down", active: likes == false, color: theme.downvote) { Task { await onDown() } }
    }
    .padding(.horizontal, compact ? 12 : 14)
    .padding(.vertical, compact ? 7 : 9)
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func voteButton(_ symbol: String, active: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: compact ? 13 : 15, weight: .bold))
        .foregroundStyle(active ? color : .secondary)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Link chip

struct AuroraLinkChip: View {
  let domain: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Label(domain, systemImage: "safari.fill")
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(theme.chipFill, in: .capsule)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Community header (feed)

struct AuroraCommunityHeader: View {
  @ObservedObject var sub: Subreddit
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        AuroraSubIcon(name: sub.data?.display_name ?? sub.id, iconKit: sub.data?.subredditIconKit, size: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text(sub.displayTitle).font(.title3.weight(.bold))
          if let members = sub.data?.subscribers, members > 0 {
            Text("\(formatBigNumber(members)) members")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        joinButton
      }
      if let about = sub.data?.public_description, !about.isEmpty {
        Text(about)
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7)
    )
    .onAppear {
      Task {
        if sub.needsAuroraMetadataRefresh {
          await sub.refreshSubreddit()
        }
      }
    }
  }

  private var joinButton: some View {
    let joined = sub.data?.user_is_subscriber ?? false
    return Button {
      sub.subscribeToggle(optimistic: true)
    } label: {
      Text(joined ? "Joined" : "Join")
        .font(.subheadline.weight(.bold))
        .foregroundStyle(joined ? theme.accent : (theme.isDark ? .black : .white))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(joined ? theme.chipFill : theme.accent, in: .capsule)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Feed card

/// Plain snapshot of the PostLink settings the Aurora card needs. `PostLinkDefSettings`
/// is a Codable `Defaults.Serializable` with a custom decoder, so every `@Default` read
/// JSON-decodes the whole struct (it showed up in scroll-hitch stacks as a per-frame /
/// per-card decode). The feed decodes it ONCE per body eval and threads this value down
/// (via `.environment(\.auroraCardSettings)`); the hot card/feed bodies never decode.
struct AuroraCardSettings: Equatable {
  var blurNSFW: Bool = true
  var isMediaTappable: Bool = true
  var maxMediaHeightPct: Double = 100
  var lightboxReadsPost: Bool = false
  var readOnScroll: Bool = false

  init() {}

  init(_ s: PostLinkDefSettings) {
    blurNSFW = s.blurNSFW
    isMediaTappable = s.isMediaTappable
    maxMediaHeightPct = s.maxMediaHeightScreenPercentage
    lightboxReadsPost = s.lightboxReadsPost
    readOnScroll = s.readOnScroll
  }
}

extension EnvironmentValues {
  @Entry var auroraCardSettings = AuroraCardSettings()
}

struct AuroraPostCardRow: View {
  @ObservedObject var post: Post
  var availableRowWidth: CGFloat? = nil
  var isSelected: Bool = false
  var onCompactNavigate: ((NavDest) -> Void)? = nil
  var onSelect: (() -> Void)? = nil
  /// Decoded once by the owning feed and threaded down. When nil (non-feed surfaces
  /// like Search / MultiPosts / MixedContent), it's decoded once here per row body —
  /// same cost and behavior as before, but the value still flows to the card via env.
  var settings: AuroraCardSettings? = nil

  @State private var measuredCardWidth: CGFloat = 0

  private var rowWidth: CGFloat? {
    availableRowWidth.map { max(1, $0) }
  }

  private var cardWidth: CGFloat {
    if let rowWidth {
      return max(1, rowWidth - 28)
    }
    return measuredCardWidth
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if rowWidth == nil {
        Color.clear
          .frame(height: 0)
          .frame(maxWidth: .infinity)
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
          } action: { newWidth in
            let measuredWidth = max(1, newWidth)
            guard abs(measuredWidth - measuredCardWidth) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              ScrollPerfProbe.shared.bump("auroraRowWidthChange")
              measuredCardWidth = measuredWidth
            }
          }
      }

      if cardWidth > 0 {
        AuroraCard(
          post: post,
          cardWidth: cardWidth,
          isSelected: isSelected,
          onCompactNavigate: onCompactNavigate
        )
        .frame(width: cardWidth, alignment: .leading)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .frame(width: rowWidth, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .modifier(AuroraPostCardRowTapModifier(onSelect: onSelect))
    .environment(\.auroraCardSettings, settings ?? AuroraCardSettings(Defaults[.PostLinkDefSettings]))
  }
}

private struct AuroraPostCardRowTapModifier: ViewModifier {
  let onSelect: (() -> Void)?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let onSelect {
      content.onTapGesture(perform: onSelect)
    } else {
      content
    }
  }
}

struct AuroraCard: View {
  @ObservedObject var post: Post
  let cardWidth: CGFloat
  var isSelected: Bool = false
  var onCompactNavigate: ((NavDest) -> Void)? = nil

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("auroraCardBody")
    if let winstonData = post.winstonData {
      AuroraPostCardSurface(
        post: post,
        winstonData: winstonData,
        cardWidth: cardWidth,
        presentation: .feed(isSelected: isSelected),
        onCompactNavigate: onCompactNavigate
      )
    }
  }
}

private enum AuroraPostCardPresentation {
  case feed(isSelected: Bool)
  case embeddedCrosspost(outerPostID: String)

  var isSelected: Bool {
    if case .feed(let isSelected) = self { return isSelected }
    return false
  }

  var isEmbeddedCrosspost: Bool {
    if case .embeddedCrosspost = self { return true }
    return false
  }

  var showsContextMenu: Bool {
    !isEmbeddedCrosspost
  }

  var inlineVideoFeedKey: String? {
    if case .embeddedCrosspost(let outerPostID) = self { return outerPostID }
    return nil
  }
}

private struct AuroraPostCardSurface: View {
  @ObservedObject var post: Post
  @ObservedObject var winstonData: PostWinstonData
  let cardWidth: CGFloat
  let presentation: AuroraPostCardPresentation
  let onCompactNavigate: ((NavDest) -> Void)?
  @Environment(\.auroraTheme) private var theme
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  @Environment(\.auroraCardSettings) private var cardSettings

  /// Media is sized from the row-owned card width. The card never measures itself,
  /// so media cannot feed back into the width used to lay out the row.
  private var contentWidth: CGFloat {
    max(1, cardWidth - (cardPadding * 2))
  }

  private var cardPadding: CGFloat {
    presentation.isEmbeddedCrosspost ? 12 : 16
  }

  private var cardCornerRadius: CGFloat {
    presentation.isEmbeddedCrosspost ? min(theme.cornerRadius, 12) : theme.cornerRadius
  }

  private var inlineVideoFeedKey: String {
    presentation.inlineVideoFeedKey ?? post.id
  }

  private func markAsRead() async {
    await post.toggleSeen(true)
  }

  var body: some View {
    let _ = ScrollPerfProbe.shared.bump("auroraCardContentBody")
    if let data = post.data {
      let readOpacity = data.winstonSeen == true ? 0.6 : 1
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 8) {
          Button { openSubreddit(data.subreddit) } label: {
            HStack(spacing: 8) {
              AuroraSubIcon(name: data.subreddit, iconKit: winstonData.subreddit?.data?.subredditIconKit, size: 24)
              Text("r/\(data.subreddit)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
          }
          .buttonStyle(.borderless)
          Text("· \(Date(timeIntervalSince1970: data.created), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if data.stickied == true {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent)
          }
        }
        .opacity(readOpacity)

        Text(data.title)
          .font(.headline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .opacity(readOpacity)

        if !data.selftext.isEmpty, !hasDisplayMedia {
          Text(data.selftext).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            .opacity(readOpacity)
        }

        mediaBlock(data)

        if let flair = flairWithoutEmojis(str: data.link_flair_text)?.first, !flair.isEmpty {
          AuroraFlair(text: flair)
            .opacity(readOpacity)
        }

        HStack(spacing: 12) {
          Button { openAuthor(data.author) } label: {
            HStack(spacing: 6) {
              AuroraAvatar(name: data.author, avatarRequest: winstonData.avatarImageRequest, size: 20)
              Text("u/\(data.author)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .buttonStyle(.borderless)
          Spacer(minLength: 8)
          Label(formatBigNumber(data.num_comments), systemImage: "bubble.left.fill")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
          NativeVoteControl(
            likes: data.likes,
            score: data.ups,
            onUp: { _ = await post.vote(.up) },
            onDown: { _ = await post.vote(.down) }
          )
          .buttonStyle(.borderless)
        }
        .opacity(readOpacity)
      }
      .padding(cardPadding)
      .frame(width: cardWidth, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
          .stroke(presentation.isSelected ? theme.accent.opacity(0.9) : theme.hairline,
                  lineWidth: presentation.isSelected ? 1.8 : 0.7)
      )
      .contentShape(Rectangle())
      .modifier(AuroraPostCardRowTapModifier(onSelect: presentation.isEmbeddedCrosspost ? openPost : nil))
      .modifier(AuroraConditionalContextMenu(isEnabled: presentation.showsContextMenu) {
        contextMenuItems(data)
      })
    }
  }

  // MARK: - Card actions

  private func openPost() {
    navigate(.reddit(.post(post)))
  }

  private func openAuthor(_ author: String) {
    guard !author.isEmpty, author != "[deleted]" else { return }
    navigate(.reddit(.user(User(id: author))))
  }

  private func openSubreddit(_ name: String) {
    guard !name.isEmpty else { return }
    navigate(.reddit(.subFeed(Subreddit(id: name))))
  }

  private func navigate(_ destination: NavDest) {
    if hSize == .compact, let onCompactNavigate {
      onCompactNavigate(destination)
    } else {
      navigateRedditDestination(destination, model: redditNavigationModel, origin: redditNavigationOrigin)
    }
  }

  private func permalink(_ data: PostData) -> URL? {
    URL(string: "https://reddit.com\(data.permalink.escape.urlEncoded)")
  }

  @ViewBuilder
  private func contextMenuItems(_ data: PostData) -> some View {
    Button { Task { _ = await post.vote(.up) } } label: { Label("Upvote", systemImage: "arrow.up") }
    Button { Task { _ = await post.vote(.down) } } label: { Label("Downvote", systemImage: "arrow.down") }
    Button { SaveChooserInstance.shared.enable(.post(post)) } label: {
      Label(data.saved ? "Unsave" : "Save", systemImage: data.saved ? "bookmark.fill" : "bookmark")
    }
    Button { ReplyModalInstance.shared.enable(.post(post)) } label: {
      Label("Reply", systemImage: "arrowshape.turn.up.left")
    }
    Divider()
    Button { openAuthor(data.author) } label: { Label("u/\(data.author)", systemImage: "person.circle") }
    Button { openSubreddit(data.subreddit) } label: { Label("r/\(data.subreddit)", systemImage: "rectangle.stack") }
    Divider()
    if let url = permalink(data) {
      ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        .simultaneousGesture(TapGesture().onEnded {
          Task { await post.markInteractedAsRead() }
        })
      Button {
        Task { await post.markInteractedAsRead() }
        UIPasteboard.general.url = url
      } label: { Label("Copy Link", systemImage: "link") }
    }
    Divider()
    Button {
      let layout = RenderingReportLayoutContext(
        surface: "aurora-post-context-menu",
        renderer: "aurora-card",
        rowSize: "\(cardWidth)xauto",
        bodySize: "\(contentWidth)xauto",
        postDimensions: String(describing: winstonData.postDimensions),
        forcedPostDimensions: String(describing: winstonData.postDimensionsForcedNormal),
        collapsed: nil,
        depth: nil
      )
      RenderingReportStore.shared.capturePostIssue(post: post, surface: "aurora-post-context-menu", layout: layout)
    } label: {
      Label("Report Rendering Issue", systemImage: "exclamationmark.bubble")
    }
  }

  private var hasDisplayMedia: Bool {
    guard let media = winstonData.extractedMediaForcedNormal else { return false }
    if case .link = media { return false }
    return true
  }

  @ViewBuilder
  private func mediaBlock(_ data: PostData) -> some View {
    if let media = winstonData.extractedMediaForcedNormal {
      if case .repost(let repost) = media {
        AuroraCrosspostCard(
          repost: repost,
          outerPostID: post.id,
          contentWidth: contentWidth,
          onCompactNavigate: onCompactNavigate
        )
      } else {
        PostRowMediaNative(
          postID: post.id,
          postTitle: data.title,
          badgeKit: data.badgeKit,
          avatarImageRequest: winstonData.avatarImageRequest,
          media: media,
          over18: data.over_18 ?? false,
          blurNSFW: cardSettings.blurNSFW,
          isMediaTappable: cardSettings.isMediaTappable,
          compact: false,
          columnWidth: contentWidth,
          compactThumbnailSize: cardSettings.compactThumbnailSize,
          maxMediaHeightPct: cardSettings.maxMediaHeightPct,
          cornerRadius: theme.mediaRadius,
          marksSeenOnPreview: cardSettings.lightboxReadsPost,
          markAsSeen: markAsRead,
          dimsTheme: AuroraPostPresentation.mediaTheme,
          feedItemKey: inlineVideoFeedKey,
          resetVideo: nil
        )
        .equatable()
        .trackInlineVideoCenter(key: inlineVideoFeedKey, coordinateSpace: "auroraFeed", enabled: media.isInlineVideo)
      }
    }
  }
}

private struct AuroraConditionalContextMenu<MenuItems: View>: ViewModifier {
  let isEnabled: Bool
  let menuItems: () -> MenuItems

  init(isEnabled: Bool, @ViewBuilder menuItems: @escaping () -> MenuItems) {
    self.isEnabled = isEnabled
    self.menuItems = menuItems
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.contextMenu(menuItems: menuItems)
    } else {
      content
    }
  }
}

struct AuroraCrosspostCard: View {
  @ObservedObject var repost: Post
  let outerPostID: String
  let contentWidth: CGFloat
  var onCompactNavigate: ((NavDest) -> Void)? = nil
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  private var cardWidth: CGFloat {
    max(1, contentWidth)
  }

  var body: some View {
    if let data = repost.data, let repostWinstonData = repost.winstonData {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.2.squarepath")
          Text("Crossposted from r/\(data.subreddit)")
            .fontWeight(.medium)
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right")
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture { openOriginalPost() }

        AuroraPostCardSurface(
          post: repost,
          winstonData: repostWinstonData,
          cardWidth: cardWidth,
          presentation: .embeddedCrosspost(outerPostID: outerPostID),
          onCompactNavigate: onCompactNavigate
        )
      }
      .frame(width: cardWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func openOriginalPost() {
    if hSize == .compact, let onCompactNavigate {
      onCompactNavigate(.reddit(.post(repost)))
    } else {
      navigateRedditDestination(.reddit(.post(repost)), model: redditNavigationModel, origin: redditNavigationOrigin)
    }
  }
}
