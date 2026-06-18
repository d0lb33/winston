//
//  TapTargetE2EHarness.swift
//  winston
//
//  A deterministic fixture screen (gated by `--winston-taptarget-e2e`) that renders the REAL
//  comment + feed-card views with mock data so UI tests can verify tap targets precisely,
//  without live Reddit. It exercises the actual `CommentRowView` collapse wiring and the
//  `AuroraPostCardRow` media/open hit regions. Author/link taps are captured into a sink
//  (no live navigation / browser); a hidden `taptarget.lastAction` Text surfaces the result.
//

import SwiftUI
import Nuke

enum TapTargetE2ELaunch {
  static let argument = "--winston-taptarget-e2e"
  static var isEnabled: Bool {
    ProcessInfo.processInfo.arguments.contains(argument)
  }
}

/// Records the last captured non-collapse action (author tap, link open, card open) so UI
/// tests can assert which control won a tap.
@Observable
@MainActor
final class TapTargetSink {
  var lastAction = "none"
}

/// Stub navigator: records reddit-destination taps (e.g. opening an author profile) instead of
/// pushing real navigation, so the fixture stays a single screen.
@MainActor
final class TapTargetNav: RedditNavigator {
  let sink: TapTargetSink
  init(sink: TapTargetSink) { self.sink = sink }
  func navigate(_ destination: NavDest, from origin: RedditNavigationOrigin) {
    switch destination {
    case .reddit(.user(let user)): sink.lastAction = "author:\(user.id)"
    default: sink.lastAction = "nav:\(destination.diagnosticsName)"
    }
  }
}

struct TapTargetE2EHarnessView: View {
  @State private var sink: TapTargetSink
  @State private var nav: TapTargetNav
  @State private var model: CommentTreeModel
  private let fixturePost: Post

  init() {
    let sink = TapTargetSink()
    _sink = State(initialValue: sink)
    _nav = State(initialValue: TapTargetNav(sink: sink))

    // Unique postID per launch so persisted collapse state never carries between test runs
    // (the fixture must always start fully expanded).
    let model = CommentTreeModel(postID: "taptarget-\(UUID().uuidString)")
    model.setRoots(Self.buildFixtureComments())
    _model = State(initialValue: model)

    let post = Post(data: postSampleData)
    if let url = URL(string: "https://winston.cafe/tim-cook-hugging-winston.jpg") {
      let media = MediaExtractedType.imgs([
        ImgExtracted(url: url, size: CGSize(width: 1200, height: 800), request: ImageRequest(url: url))
      ])
      post.winstonData?.extractedMedia = media
      post.winstonData?.extractedMediaForcedNormal = media
    }
    fixturePost = post
  }

  var body: some View {
    GeometryReader { geo in
      List {
        Text(verbatim: "lastAction: \(sink.lastAction)")
          .font(.caption2)
          .accessibilityIdentifier("taptarget.lastAction")
          .listRowSeparator(.hidden)

        // Real comment rows first (kept near the top so coordinate taps land on screen),
        // driven by the real CommentTreeModel.
        ForEach(model.rows) { row in
          CommentRowView(
            row: row,
            comment: row.comment,
            model: model,
            post: nil,
            postFullname: "t3_taptarget",
            opAuthor: nil,
            swipeActions: DEFAULT_COMMENT_SWIPE_ACTIONS,
            maxMediaHeightPct: 0.5,
            contentWidth: geo.size.width
          )
          .accessibilityIdentifier("taptarget.comment.\(row.id)")
        }

        // Real feed card — tapping the title/header must open the post; only the visible
        // image opens fullscreen. Media height kept small so the card fits for tap tests.
        AuroraPostCardRow(
          post: fixturePost,
          availableRowWidth: geo.size.width,
          onSelect: { sink.lastAction = "openPost" },
          settings: Self.cardSettings
        )
        .accessibilityIdentifier("taptarget.card")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
      }
      .listStyle(.plain)
      .environment(\.auroraTheme, AuroraTheme.midnight)
      .environment(\.auroraCardSettings, Self.cardSettings)
      .redditNavigation(nav, origin: .content)
      // Capture markdown link taps (so a link opens "something" and does not collapse).
      .environment(\.openURL, OpenURLAction { url in
        sink.lastAction = "link:\(url.absoluteString)"
        return .handled
      })
    }
  }

  // MARK: - Fixtures

  /// Media tappable (so the visible image opens fullscreen) but short, so the card fits.
  private static var cardSettings: AuroraCardSettings {
    var settings = AuroraCardSettings()
    settings.isMediaTappable = true
    settings.maxMediaHeightPct = 25
    return settings
  }

  private static func makeCommentData(
    _ id: String,
    author: String,
    body: String,
    replies: [CommentData] = []
  ) -> CommentData {
    var data = CommentData(id: id)
    data.author = author
    data.author_fullname = "t2_\(id)"
    data.body = body
    data.created = Date().timeIntervalSince1970 - 3600
    data.ups = 12
    if !replies.isEmpty {
      var listingData = ListingData<CommentData>(after: nil, dist: nil, modhash: nil, geo_filter: nil)
      listingData.children = replies.map { reply in
        // kind nil → the child Comment's id stays its bare data.id (no kind suffix), so the
        // accessibility identifiers (taptarget.comment.<id>) match the fixture ids.
        var child = ListingChild<CommentData>(kind: nil)
        child.data = reply
        return child
      }
      var listing = Listing<CommentData>(kind: "Listing")
      listing.data = listingData
      data.replies = .second(listing)
    }
    return data
  }

  /// A small, deterministic forest:
  /// - alpha (RootAlpha) → beta (ReplyBeta) → beta1 (ReplyBeta1); gamma (ReplyGamma)
  /// - delta (RootDelta, body is a link) → deltachild (ReplyDelta)
  static func buildFixtureComments() -> [Comment] {
    let beta1 = makeCommentData("beta1", author: "ReplyBeta1", body: "Nested reply, depth two.")
    let beta = makeCommentData("beta", author: "ReplyBeta", body: "First reply to alpha.", replies: [beta1])
    let gamma = makeCommentData("gamma", author: "ReplyGamma", body: "Second reply to alpha.")
    let alpha = makeCommentData(
      "alpha",
      author: "RootAlpha",
      // Two lines so the body region sits clearly below the header's vote controls (keeps the
      // trailing-padding tap test off the downvote button).
      body: "Tap anywhere on this comment to collapse it. The gutter, the padding, and this body text all collapse.",
      replies: [beta, gamma]
    )
    let deltaChild = makeCommentData("deltachild", author: "ReplyDelta", body: "Reply under the link comment.")
    let delta = makeCommentData(
      "delta",
      author: "RootDelta",
      body: "[Tap this link — it should open and must not collapse the comment](https://example.com/winston)",
      replies: [deltaChild]
    )
    return [Comment(data: alpha), Comment(data: delta)]
  }
}
