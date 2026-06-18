//
//  AuroraPostDetailConcepts.swift
//  winston
//
//  Design Lab — three Liquid-Glass-forward takes on the IMMERSIVE post-detail direction,
//  rendered against the self-contained mock dataset (no network, no production models).
//  Each opens full-screen from the Design Lab gallery.
//
//  ─────────────────────────────────────────────────────────────────────────────────────
//  FREEZE POSTMORTEM — the earlier hang was NOT the glass. The console showed an
//  "Observation tracking feedback loop" with the nav-bar safe-area inset oscillating
//  62 ↔ 0: `.toolbarMinimizeBehavior(.onScrollDown,…)` minimised the bar on scroll, which
//  shrank the safe area, which shifted the (12 000pt-tall) content, which re-triggered the
//  minimise — an infinite layout loop that froze the app. The fix is simply NOT to use
//  `.toolbarMinimizeBehavior` here. With that gone, real `.glassEffect` on the scrolling
//  content is fine (a recycling List only realises ~12 rows, and the backdrop is static).
//  ─────────────────────────────────────────────────────────────────────────────────────
//
//  All three share the Immersive recipe — blurred post-media backdrop, a native Liquid
//  Glass toolbar (reliable Close), hundreds of nested comments through a recycling List,
//  and a post-type switcher — but differ in their glass treatment:
//   • Halo   — glass post card + glass top-level comment cards (replies translucent), with
//              a fixed floating GlassEffectContainer action cluster.
//   • Sheet  — one continuous pane of Liquid Glass holds the whole thread, hairline-ruled.
//   • Liquid — accent-tinted glass everywhere, OP comments glowing, and a fixed floating
//              glass FAB stack that lights up as you vote.
//
//  ABSTRACTION MAP — every variation is the same four pieces, same order, as the real
//  `AuroraPostDetail`: post header → action bar → comment rows (List) → composer.
//

import SwiftUI
import Observation

// MARK: - Concept registry (three Immersive variations)

enum AuroraDetailConcept: String, Identifiable, CaseIterable {
  case halo, sheet, liquid

  var id: String { rawValue }

  var title: String {
    switch self {
    case .halo:   "Halo"
    case .sheet:  "Sheet"
    case .liquid: "Liquid"
    }
  }

  var tagline: String {
    switch self {
    case .halo:   "Immersive · glass cards"
    case .sheet:  "Immersive · one glass pane"
    case .liquid: "Immersive · tinted glass + FAB"
    }
  }

  var blurb: String {
    switch self {
    case .halo:   "Glass post and top-level comment cards float over the blurred media, with a floating Liquid Glass action cluster pinned at the bottom."
    case .sheet:  "Post and every reply share one continuous pane of Liquid Glass, separated by hairlines, with a glass composer below."
    case .liquid: "Accent-tinted glass throughout, the original poster glowing, and a floating glass control stack that lights up as you vote."
    }
  }

  var symbol: String {
    switch self {
    case .halo:   "circle.hexagongrid.fill"
    case .sheet:  "rectangle.portrait.fill"
    case .liquid: "drop.fill"
    }
  }

  var theme: AuroraTheme { .midnight }
  var prefersDarkText: Bool { false }

  var galleryGradient: [Color] {
    let m = theme.meshColors
    switch self {
    case .halo:   return [m[1], m[4], m[7]]
    case .sheet:  return [m[0], m[3], m[8]]
    case .liquid: return [m[2], m[5], m[8]]
    }
  }

  @MainActor @ViewBuilder func detail(onClose: @escaping () -> Void) -> some View {
    switch self {
    case .halo:   HaloDetail(onClose: onClose)
    case .sheet:  SheetDetail(onClose: onClose)
    case .liquid: LiquidDetail(onClose: onClose)
    }
  }
}

// MARK: - Full-screen host

struct AuroraDetailConceptPreview: View {
  let concept: AuroraDetailConcept
  let onClose: () -> Void

  var body: some View {
    concept.detail(onClose: onClose)
      .environment(\.auroraTheme, concept.theme)
      .preferredColorScheme(concept.theme.colorScheme)
      .tint(concept.theme.accent)
      .fontDesign(concept.theme.fontDesign)
      .designLabImageSession()
  }
}

// MARK: - Gallery section (dropped into DesignLabGallery)

struct PostDetailConceptSection: View {
  @State private var presented: AuroraDetailConcept?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Immersive · Liquid Glass")
          .font(.title2.weight(.bold))
        Text("Three glassier takes on the Immersive post detail — switch post type (text · photo · gallery · link) inside each, scroll hundreds of nested comments, tap Close in the bar to return.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      ForEach(AuroraDetailConcept.allCases) { concept in
        Button { presented = concept } label: {
          DetailConceptCard(concept: concept)
        }
        .buttonStyle(.plain)
      }
    }
    .fullScreenCover(item: $presented) { concept in
      AuroraDetailConceptPreview(concept: concept) { presented = nil }
    }
  }
}

private struct DetailConceptCard: View {
  let concept: AuroraDetailConcept
  private var foreground: Color { concept.prefersDarkText ? Color(red: 0.16, green: 0.12, blue: 0.10) : .white }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: concept.symbol)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(width: 46, height: 46)
        .background(foreground.opacity(0.14), in: .circle)

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(concept.title)
            .font(.system(size: 23, weight: .heavy))
            .foregroundStyle(foreground)
          Spacer()
          Label("Open", systemImage: "arrow.up.right")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(foreground.opacity(0.16), in: .capsule)
            .foregroundStyle(foreground)
        }
        Text(concept.tagline.uppercased())
          .font(.caption2.weight(.semibold)).tracking(1.1)
          .foregroundStyle(foreground.opacity(0.72))
        Text(concept.blurb)
          .font(.subheadline)
          .foregroundStyle(foreground.opacity(0.86))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(LinearGradient(colors: concept.galleryGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.7))
    .shadow(color: concept.theme.accent.opacity(0.26), radius: 16, x: 0, y: 9)
  }
}

// MARK: - Shared state

@Observable @MainActor final class ConceptDetailModel {
  var post: MockPost
  private(set) var roots: [MockComment]
  private(set) var visibleRows: [(comment: MockComment, depth: Int, isCollapsed: Bool)]
  let totalComments: Int
  var collapsed: Set<String> = [] { didSet { recomputeRows() } }
  var voteDir = 0
  var saved = false

  init(_ post: MockPost) {
    self.post = post
    let roots = MockData.largeComments(for: post)
    self.roots = roots
    self.totalComments = roots.reduce(0) { $0 + 1 + $1.descendantCount }
    self.visibleRows = MockComment.visibleRows(roots, collapsed: [])
  }

  var score: Int { post.score + voteDir }

  private func recomputeRows() {
    visibleRows = MockComment.visibleRows(roots, collapsed: collapsed)
  }

  func select(_ p: MockPost) {
    guard p.id != post.id else { return }
    post = p
    roots = MockData.largeComments(for: p)
    collapsed = []          // triggers recompute
    voteDir = 0
    saved = false
  }
  func toggle(_ id: String) {
    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
  }
  func up()   { voteDir = voteDir == 1 ? 0 : 1 }
  func down() { voteDir = voteDir == -1 ? 0 : -1 }
}

// MARK: - Shared chrome (NavigationStack + glass toolbar + reliable Close + backdrop)
//
// NOTE: deliberately NO `.toolbarMinimizeBehavior` — it created an inset/layout feedback
// loop that froze the app (see the postmortem at the top of this file).

private struct ConceptChrome: ViewModifier {
  let model: ConceptDetailModel
  let onClose: () -> Void
  @Binding var sort: String
  var darken: Double = 0.5
  var lighten: Double = 0
  var vignette: Bool = false
  let theme: AuroraTheme

  @State private var blurRadius: Double = 12
  @State private var showBlur = false

  private var postTypeBinding: Binding<String> {
    Binding(
      get: { model.post.id },
      set: { id in
        if let p = MockData.showcasePosts.first(where: { $0.id == id }) {
          withAnimation(.smooth) { model.select(p) }
        }
      }
    )
  }

  func body(content: Content) -> some View {
    NavigationStack {
      content
        .scrollContentBackground(.hidden)
        .navigationTitle(model.post.subreddit.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button { onClose() } label: { Image(systemName: "xmark") }
              .accessibilityLabel("Close preview")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button { showBlur = true } label: { Image(systemName: "slider.horizontal.3") }
              .accessibilityLabel("Adjust backdrop blur")
              .popover(isPresented: $showBlur) {
                BackdropBlurControl(blur: $blurRadius)
                  .presentationCompactAdaptation(.popover)
              }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Picker("Sort", selection: $sort) {
                ForEach(["Top", "Best", "New", "Controversial", "Old"], id: \.self) { Text($0).tag($0) }
              }
            } label: {
              Label("Sort", systemImage: "arrow.up.arrow.down")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Picker("Post type", selection: postTypeBinding) {
                ForEach(MockData.showcasePosts, id: \.id) { p in
                  Label(kindLabel(p.kind), systemImage: kindIcon(p.kind)).tag(p.id)
                }
              }
            } label: {
              Image(systemName: "rectangle.on.rectangle.angled")
            }
          }
        }
        .background { MediaBackdrop(post: model.post, theme: theme, darken: darken, lighten: lighten, vignette: vignette, blurRadius: blurRadius) }
    }
    .tint(theme.accent)
  }
}

private extension View {
  func conceptChrome(model: ConceptDetailModel, onClose: @escaping () -> Void, sort: Binding<String>,
                     darken: Double = 0.5, lighten: Double = 0, vignette: Bool = false, theme: AuroraTheme) -> some View {
    modifier(ConceptChrome(model: model, onClose: onClose, sort: sort, darken: darken, lighten: lighten, vignette: vignette, theme: theme))
  }
}

/// Live backdrop-blur control shown in a popover from the top bar. 0 = sharp media (the
/// glass refracts crisp content and pops most); higher = softer atmosphere.
private struct BackdropBlurControl: View {
  @Binding var blur: Double
  private let presets: [(String, Double)] = [("None", 0), ("Subtle", 10), ("Medium", 28), ("Heavy", 50)]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Backdrop blur").font(.headline)
      HStack(spacing: 10) {
        Image(systemName: "drop").foregroundStyle(.secondary)
        Slider(value: $blur, in: 0...60, step: 1)
        Text("\(Int(blur))")
          .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
          .frame(width: 26, alignment: .trailing)
      }
      HStack(spacing: 8) {
        ForEach(presets, id: \.0) { name, value in
          Button(name) { withAnimation(.snappy) { blur = value } }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
            .tint(abs(blur - value) < 0.5 ? Color.accentColor : .secondary)
        }
      }
    }
    .padding(18)
    .frame(width: 290)
  }
}

private func kindLabel(_ kind: MockPostKind) -> String {
  switch kind {
  case .text:    "Text post"
  case .image:   "Photo"
  case .video:   "Video"
  case .gallery: "Gallery"
  case .link:    "Link"
  }
}

private func kindIcon(_ kind: MockPostKind) -> String {
  switch kind {
  case .text:    "text.alignleft"
  case .image:   "photo"
  case .video:   "play.rectangle"
  case .gallery: "square.stack.3d.up"
  case .link:    "link"
  }
}

// MARK: - Glass + frosted surfaces

private extension View {
  /// Real Liquid Glass card (optionally tinted). Safe on scrolling content now that the
  /// toolbar-minimise feedback loop is gone.
  func glassCard(_ cornerRadius: CGFloat, tint: Color? = nil) -> some View {
    glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }

  /// Cheap translucent fill (no live blur) for deep replies / chips where glass would be
  /// visual overkill.
  func frosted(_ cornerRadius: CGFloat, fill: Color, stroke: Double = 0.08) -> some View {
    self
      .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(stroke), lineWidth: 0.5))
  }
}

// MARK: - Backdrop (blurred post media → scrim; gradient fallback for text/link)

struct MediaBackdrop: View {
  let post: MockPost
  let theme: AuroraTheme
  var darken: Double = 0.45
  var lighten: Double = 0
  var vignette: Bool = false
  /// 0 = sharp media (glass refracts crisp content → pops most). Higher = softer atmosphere.
  var blurRadius: Double = 12

  private var seed: String? {
    guard let m = post.media else { return nil }
    return post.kind == .gallery ? "\(m.seed)-0" : m.seed
  }

  private var px: Int { blurRadius < 4 ? 1200 : 700 }   // crisp source when barely blurred

  var body: some View {
    ZStack {
      if let seed {
        SeededRemoteImage(seed: seed, pixelWidth: px, pixelHeight: px, showSymbol: false)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .scaleEffect(1.0 + min(blurRadius, 60) / 250)
          .blur(radius: blurRadius, opaque: true)
        Color.black.opacity(darken)
        theme.accent.opacity(0.07)
      } else {
        LinearGradient(colors: theme.meshColors, startPoint: .topLeading, endPoint: .bottomTrailing)
        Color.black.opacity(darken * 0.5)
      }
      if lighten > 0 { Color.white.opacity(lighten) }
      if vignette {
        RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 150, endRadius: 640)
      }
    }
    .ignoresSafeArea()
  }
}

// MARK: - Media (per post kind)

struct ConceptMediaView: View {
  let post: MockPost
  var cornerRadius: CGFloat = 16

  var body: some View {
    switch post.kind {
    case .text:
      EmptyView()
    case .image, .video:
      if let m = post.media {
        ConceptMedia(seed: m.seed, aspect: m.aspect, cornerRadius: cornerRadius, blurred: post.isNSFW || post.isSpoiler)
      }
    case .gallery:
      if let m = post.media {
        GalleryStrip(seed: m.seed, count: m.count, cornerRadius: cornerRadius, blurred: post.isNSFW || post.isSpoiler)
      }
    case .link:
      LinkCard(post: post, cornerRadius: cornerRadius)
    }
  }
}

struct ConceptMedia: View {
  let seed: String
  var aspect: CGFloat = 1.5
  var cornerRadius: CGFloat = 16
  var blurred = false

  var body: some View {
    SeededRemoteImage(seed: seed, pixelWidth: 1200, pixelHeight: max(1, Int(1200 / aspect)), blurred: blurred)
      .aspectRatio(aspect, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

struct GalleryStrip: View {
  let seed: String
  let count: Int
  var cornerRadius: CGFloat = 16
  var blurred = false
  @State private var index = 0

  var body: some View {
    VStack(spacing: 8) {
      TabView(selection: $index) {
        ForEach(0..<count, id: \.self) { i in
          SeededRemoteImage(seed: "\(seed)-\(i)", pixelWidth: 1000, pixelHeight: 760, blurred: blurred)
            .frame(maxWidth: .infinity)
            .frame(height: 250)
            .clipped()
            .tag(i)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .frame(height: 250)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(alignment: .topTrailing) {
        Text("\(index + 1) / \(count)")
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.45), in: .capsule)
          .padding(8)
      }

      HStack(spacing: 5) {
        ForEach(0..<count, id: \.self) { i in
          Circle()
            .fill(i == index ? Color.primary : Color.secondary.opacity(0.35))
            .frame(width: 6, height: 6)
        }
      }
    }
  }
}

struct LinkCard: View {
  let post: MockPost
  var cornerRadius: CGFloat = 16
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: 12) {
      SeededRemoteImage(seed: post.media?.seed ?? post.id, pixelWidth: 240, pixelHeight: 240)
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: post.linkDomain ?? "link")
          .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
        Text(post.title)
          .font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
      }
      Spacer(minLength: 4)
      Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
    }
    .padding(12)
    .frosted(cornerRadius, fill: theme.chipFill)
  }
}

// MARK: - Small shared atoms

struct ConceptSubIcon: View {
  let sub: MockSubreddit
  var size: CGFloat = 28
  private var letter: String { String((sub.name.first { $0.isLetter || $0.isNumber } ?? "r")).uppercased() }
  var body: some View {
    Circle()
      .fill(LinearGradient(colors: [sub.accent.color, sub.accent.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
      .frame(width: size, height: size)
      .overlay(Text(letter).font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white))
  }
}

struct ConceptAvatar: View {
  let seed: String
  var size: CGFloat = 26
  var body: some View {
    SeededRemoteImage(seed: seed, service: .avatar, pixelWidth: Int(size * 3), pixelHeight: Int(size * 3), showSymbol: false)
      .frame(width: size, height: size)
      .clipShape(Circle())
  }
}

private struct OPBadge: View {
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Text("OP")
      .font(.system(size: 9, weight: .heavy))
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(theme.accent.opacity(0.22), in: .capsule)
      .foregroundStyle(theme.accent)
  }
}

private struct ConceptPostMeta: View {
  let post: MockPost
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    HStack(spacing: 9) {
      ConceptSubIcon(sub: post.subreddit, size: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(post.subreddit.displayName).font(.subheadline.weight(.bold))
        Text("u/\(post.author.username) · \(MockFormatting.relativeTime(post.createdOffset))")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      if post.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent) }
    }
  }
}

private struct PostFlair: View {
  let text: String
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    Text(text).font(.caption2.weight(.semibold))
      .padding(.horizontal, 9).padding(.vertical, 4)
      .background(theme.accent.opacity(0.22), in: .capsule)
      .foregroundStyle(theme.accent)
  }
}

/// Plain interactive vote cluster (no glass) — sits over a glass surface; plain buttons +
/// a single non-interactive glass shape is the only combination SwiftUI hit-tests reliably.
private struct VoteCluster: View {
  let model: ConceptDetailModel
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    HStack(spacing: 12) {
      Button { withAnimation(.snappy) { model.up() } } label: {
        Image(systemName: "arrow.up").foregroundStyle(model.voteDir == 1 ? theme.accent : .secondary)
      }
      Text(MockFormatting.compactNumber(model.score))
        .font(.subheadline.weight(.bold)).monospacedDigit()
        .contentTransition(.numericText())
        .foregroundStyle(model.voteDir == 1 ? theme.accent : model.voteDir == -1 ? theme.downvote : .primary)
      Button { withAnimation(.snappy) { model.down() } } label: {
        Image(systemName: "arrow.down").foregroundStyle(model.voteDir == -1 ? theme.downvote : .secondary)
      }
    }
    .font(.system(size: 15, weight: .bold))
    .buttonStyle(.plain)
  }
}

private struct CommentMetaLine: View {
  let comment: MockComment
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    HStack(spacing: 6) {
      ConceptAvatar(seed: comment.author.avatarSeed, size: 19)
      Text("u/\(comment.author.username)")
        .font(.caption.weight(.semibold))
        .foregroundStyle(comment.isOP ? theme.accent : .primary)
      if comment.isOP { OPBadge() }
      Text("· \(MockFormatting.relativeTime(comment.createdOffset))").font(.caption2).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
      Text(MockFormatting.compactNumber(comment.score)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
  }
}

@ViewBuilder
private func collapsedOrBody(_ comment: MockComment, isCollapsed: Bool, tint: Color) -> some View {
  if isCollapsed {
    Text("\(comment.descendantCount) more " + (comment.descendantCount == 1 ? "reply" : "replies"))
      .font(.caption.weight(.medium)).foregroundStyle(tint)
  } else {
    Text(comment.body).font(.subheadline).foregroundStyle(.primary.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
  }
}

/// Shared post header block (scrolls).
private struct ConceptPostHeader: View {
  let model: ConceptDetailModel
  var showInlineStats: Bool = true
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ConceptPostMeta(post: model.post)
      Text(model.post.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
      if let flair = model.post.flair { PostFlair(text: flair.text) }
      ConceptMediaView(post: model.post, cornerRadius: theme.mediaRadius)
      if let body = model.post.body, !body.isEmpty {
        Text(body).font(.callout).foregroundStyle(.primary.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
      }
      if showInlineStats {
        HStack(spacing: 16) {
          Label("\(MockFormatting.compactNumber(model.score)) points", systemImage: "arrow.up")
          Label(MockFormatting.compactNumber(model.totalComments), systemImage: "bubble.left.fill")
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.top, 2)
      }
    }
  }
}

// MARK: ─────────────────────────────────────────────────────────────────────────────────
// MARK: 1 — HALO  (glass cards + fixed floating glass action cluster)
// MARK: ─────────────────────────────────────────────────────────────────────────────────

struct HaloDetail: View {
  let onClose: () -> Void
  @Environment(\.auroraTheme) private var theme
  @State private var model = ConceptDetailModel(MockData.showcasePosts[1])
  @State private var sort = "Top"

  var body: some View {
    List {
      Section {
        ConceptPostHeader(model: model)
          .padding(16)
          .glassCard(theme.cornerRadius)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      Section {
        Text("\(model.totalComments) Comments")
          .font(.headline)
          .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
        ForEach(model.visibleRows, id: \.comment.id) { row in
          HaloCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed) {
            withAnimation(.snappy) { model.toggle(row.comment.id) }
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSpacing(10)
    .environment(\.defaultMinListRowHeight, 1)
    .safeAreaInset(edge: .bottom) { bottomBar }
    .conceptChrome(model: model, onClose: onClose, sort: $sort, darken: 0.52, theme: theme)
  }

  // FIXED → real Liquid Glass is safe. GlassEffectContainer groups the controls.
  private var bottomBar: some View {
    GlassEffectContainer(spacing: 10) {
      HStack(spacing: 10) {
        VoteCluster(model: model)
          .padding(.horizontal, 16).padding(.vertical, 11)
          .glassEffect(.regular, in: .capsule)
        Label(MockFormatting.compactNumber(model.totalComments), systemImage: "bubble.left.fill")
          .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.vertical, 11)
          .glassEffect(.regular, in: .capsule)
        Spacer(minLength: 0)
        Button { withAnimation(.snappy) { model.saved.toggle() } } label: {
          Image(systemName: model.saved ? "bookmark.fill" : "bookmark")
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(model.saved ? theme.accent : .secondary)
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        Image(systemName: "square.and.arrow.up")
          .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
          .frame(width: 46, height: 46)
          .glassEffect(.regular, in: .circle)
      }
    }
    .padding(.horizontal, 16).padding(.bottom, 8)
  }
}

private struct HaloCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool
  let onToggle: () -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      CommentMetaLine(comment: comment)
      collapsedOrBody(comment, isCollapsed: isCollapsed, tint: theme.accent)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(HaloRowSurface(depth: depth, isOP: comment.isOP))
    .padding(.leading, CGFloat(depth) * 14)
    .padding(.horizontal, 16).padding(.vertical, 5)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggle)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
}

/// Top-level comments are real Liquid Glass; deep replies use a cheap translucent fill so a
/// fast scroll never has to composite dozens of live-glass surfaces at the deepest tiers.
private struct HaloRowSurface: ViewModifier {
  let depth: Int
  let isOP: Bool
  @Environment(\.auroraTheme) private var theme
  func body(content: Content) -> some View {
    if depth == 0 {
      content.glassCard(16, tint: isOP ? theme.accent.opacity(0.28) : nil)
    } else {
      content.frosted(14, fill: isOP ? theme.accent.opacity(0.12) : theme.cardFill, stroke: 0.07)
    }
  }
}

// MARK: ─────────────────────────────────────────────────────────────────────────────────
// MARK: 2 — SHEET  (one continuous pane of Liquid Glass)
// MARK: ─────────────────────────────────────────────────────────────────────────────────

struct SheetDetail: View {
  let onClose: () -> Void
  @Environment(\.auroraTheme) private var theme
  @State private var model = ConceptDetailModel(MockData.showcasePosts[1])
  @State private var sort = "Top"

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ConceptPostHeader(model: model, showInlineStats: false)
          .padding(16)
        hairline
        actionRow
          .padding(.horizontal, 16).padding(.vertical, 12)
        hairline
        Text("\(model.totalComments) Comments")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        ForEach(model.visibleRows, id: \.comment.id) { row in
          SheetCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed) {
            withAnimation(.snappy) { model.toggle(row.comment.id) }
          }
          if row.comment.id != model.visibleRows.last?.comment.id {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
              .padding(.leading, CGFloat(row.depth) * 18 + 16)
          }
        }
      }
      // ONE continuous pane of Liquid Glass.
      .glassCard(26)
      .padding(.horizontal, 11)
      .padding(.top, 8)
      .padding(.bottom, 6)
    }
    .safeAreaInset(edge: .bottom) { composer }
    .conceptChrome(model: model, onClose: onClose, sort: $sort, darken: 0.5, theme: theme)
  }

  private var hairline: some View {
    Rectangle().fill(theme.hairline).frame(height: 0.5)
  }

  private var actionRow: some View {
    HStack(spacing: 14) {
      VoteCluster(model: model)
      Capsule().fill(theme.hairline).frame(width: 1, height: 16)
      Label(MockFormatting.compactNumber(model.totalComments), systemImage: "bubble.left.fill")
        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button { withAnimation(.snappy) { model.saved.toggle() } } label: {
        Image(systemName: model.saved ? "bookmark.fill" : "bookmark").foregroundStyle(model.saved ? theme.accent : .secondary)
      }
      .buttonStyle(.plain)
      Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
    }
    .font(.system(size: 16, weight: .semibold))
  }

  private var composer: some View {
    HStack(spacing: 10) {
      ConceptAvatar(seed: "winston", size: 28)
      Text("Add a comment…").font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .glassEffect(.regular, in: .capsule)
    .padding(.horizontal, 16).padding(.bottom, 8)
  }
}

private struct SheetCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool
  let onToggle: () -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      CommentMetaLine(comment: comment)
      collapsedOrBody(comment, isCollapsed: isCollapsed, tint: theme.accent)
    }
    .padding(.vertical, 9)
    .padding(.leading, CGFloat(depth) * 18 + 16)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .leading) {
      if depth > 0 {
        Rectangle().fill(theme.railColors[depth % theme.railColors.count].opacity(0.5))
          .frame(width: 2)
          .padding(.leading, CGFloat(depth) * 18 + 6)
          .padding(.vertical, 6)
      }
    }
    .background(comment.isOP ? theme.accent.opacity(0.08) : .clear)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggle)
  }
}

// MARK: ─────────────────────────────────────────────────────────────────────────────────
// MARK: 3 — LIQUID  (accent-tinted glass + fixed floating glass FAB)
// MARK: ─────────────────────────────────────────────────────────────────────────────────

struct LiquidDetail: View {
  let onClose: () -> Void
  @Environment(\.auroraTheme) private var theme
  @State private var model = ConceptDetailModel(MockData.showcasePosts[1])
  @State private var sort = "Top"

  var body: some View {
    List {
      Section {
        ConceptPostHeader(model: model)
          .padding(16)
          .glassCard(theme.cornerRadius, tint: tinted(0.16))
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      Section {
        Text("\(model.totalComments) Comments")
          .font(.headline)
          .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
        ForEach(model.visibleRows, id: \.comment.id) { row in
          LiquidCommentRow(comment: row.comment, depth: row.depth, isCollapsed: row.isCollapsed) {
            withAnimation(.snappy) { model.toggle(row.comment.id) }
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSpacing(10)
    .environment(\.defaultMinListRowHeight, 1)
    .safeAreaInset(edge: .bottom) { composer }
    .overlay(alignment: .bottomTrailing) { fabStack }
    .conceptChrome(model: model, onClose: onClose, sort: $sort, darken: 0.56, vignette: true, theme: theme)
  }

  private func tinted(_ o: Double) -> Color { theme.accent.opacity(o) }

  // FIXED overlay → real glass is safe. Tinted glass lights up as you vote / save.
  private var fabStack: some View {
    GlassEffectContainer(spacing: 10) {
      VStack(spacing: 10) {
        fab("arrow.up", active: model.voteDir == 1, tint: theme.accent) { model.up() }
        fab("arrow.down", active: model.voteDir == -1, tint: theme.downvote) { model.down() }
        fab(model.saved ? "bookmark.fill" : "bookmark", active: model.saved, tint: theme.accent) { model.saved.toggle() }
      }
    }
    .padding(.trailing, 16)
    .padding(.bottom, 92)
  }

  private func fab(_ icon: String, active: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
    Button { withAnimation(.snappy) { action() } } label: {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(active ? (theme.isDark ? .black : .white) : theme.onGlass)
        .frame(width: 52, height: 52)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(active ? tint : nil).interactive(), in: .circle)
  }

  private var composer: some View {
    HStack(spacing: 10) {
      ConceptAvatar(seed: "winston", size: 28)
      Text("Add a comment…").font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Image(systemName: "paperplane.fill")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(theme.isDark ? .black : .white)
        .frame(width: 34, height: 34)
        .background(theme.accent, in: .circle)
    }
    .padding(.horizontal, 14).padding(.vertical, 9)
    .glassEffect(.regular.tint(theme.accent.opacity(0.12)), in: .capsule)
    .padding(.leading, 16).padding(.trailing, 84).padding(.bottom, 8)
  }
}

private struct LiquidCommentRow: View {
  let comment: MockComment
  let depth: Int
  let isCollapsed: Bool
  let onToggle: () -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      CommentMetaLine(comment: comment)
      collapsedOrBody(comment, isCollapsed: isCollapsed, tint: theme.accent)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(17, tint: comment.isOP ? theme.accent.opacity(0.32) : theme.accent.opacity(0.08))
    .overlay(
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .stroke(comment.isOP ? theme.accent.opacity(0.5) : .clear, lineWidth: 0.8)
    )
    .padding(.leading, CGFloat(depth) * 15)
    .padding(.horizontal, 16).padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggle)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }
}

// MARK: - Previews

#Preview("Halo")   { AuroraDetailConceptPreview(concept: .halo,   onClose: {}) }
#Preview("Sheet")  { AuroraDetailConceptPreview(concept: .sheet,  onClose: {}) }
#Preview("Liquid") { AuroraDetailConceptPreview(concept: .liquid, onClose: {}) }
