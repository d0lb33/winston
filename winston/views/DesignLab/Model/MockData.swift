//
//  MockData.swift
//  winston
//
//  Design Lab — a static, deterministic, offline dataset shared by all three designs.
//  Pure constants → instant, preview-friendly, no network, no async.
//

import Foundation

enum MockData {

  // MARK: Users

  static let uWinston = MockUser(id: "u/winston", username: "winston", avatarSeed: "winston", karma: 128_400)
  static let uAva     = MockUser(id: "u/ava_dev", username: "ava_dev", avatarSeed: "ava", karma: 24_980)
  static let uMax     = MockUser(id: "u/maxbuilds", username: "maxbuilds", avatarSeed: "max", karma: 9_120)
  static let uLena    = MockUser(id: "u/lena.hikes", username: "lena.hikes", avatarSeed: "lena", karma: 53_700)
  static let uKenji   = MockUser(id: "u/kenji_k", username: "kenji_k", avatarSeed: "kenji", karma: 4_310)
  static let uNina    = MockUser(id: "u/nina_codes", username: "nina_codes", avatarSeed: "nina", karma: 76_220)
  static let uTheo    = MockUser(id: "u/theofold", username: "theofold", avatarSeed: "theo", karma: 18_540)
  static let uRosa    = MockUser(id: "u/rosapix", username: "rosapix", avatarSeed: "rosa", karma: 31_900)

  // MARK: Subreddits

  static let foldables = MockSubreddit(id: "r/foldables", name: "foldables", displayName: "r/foldables", about: "Everything that bends. Folds, flips, rollables and the apps that love them.", members: 184_000, iconSeed: "foldables", accent: .indigo)
  static let swift     = MockSubreddit(id: "r/swift", name: "swift", displayName: "r/swift", about: "The Swift programming language and everything you build with it.", members: 312_000, iconSeed: "swift", accent: .orange)
  static let apple     = MockSubreddit(id: "r/apple", name: "apple", displayName: "r/apple", about: "Unofficial community for Apple news, rumors and discussion.", members: 7_200_000, iconSeed: "apple", accent: .blue)
  static let earth     = MockSubreddit(id: "r/EarthPorn", name: "EarthPorn", displayName: "r/EarthPorn", about: "The landscapes of our planet, captured by you.", members: 23_100_000, iconSeed: "earth", accent: .green)
  static let prog      = MockSubreddit(id: "r/programming", name: "programming", displayName: "r/programming", about: "Computer programming — news, articles and show & tell.", members: 6_400_000, iconSeed: "prog", accent: .purple)
  static let aww       = MockSubreddit(id: "r/aww", name: "aww", displayName: "r/aww", about: "Things that make you go awww — cute and cuddly.", members: 34_800_000, iconSeed: "aww", accent: .pink)

  static let subreddits: [MockSubreddit] = [foldables, swift, apple, earth, prog, aww]

  // MARK: Feed

  static let feed: [MockPost] = [
    makePost("fold-pin", "After a week on the fold, going back to a slab phone feels ancient",
             sub: foldables, author: uTheo, kind: .text, score: 8_900, comments: 642, ago: hours(3),
             body: "I was a skeptic. The crease, the weight, the price. But the first time I opened a long thread and saw the post on one side and the whole comment tree on the other — without losing my place — something clicked. The big screen isn't a bigger phone. It's a different posture.",
             flair: MockFlair(text: "Discussion", tint: .indigo), pinned: true),

    makePost("fold-3pane", "Winston on the inner screen is unreal — three panes of pure browsing",
             sub: foldables, author: uWinston, kind: .image, score: 6_120, comments: 318, ago: hours(5),
             mediaAspect: 1.6),

    makePost("swift-glass", "SwiftUI on iOS 27: Liquid Glass is genuinely fun to build with",
             sub: swift, author: uAva, kind: .image, score: 4_530, comments: 271, ago: hours(7),
             body: "Spent the weekend porting our app to the new glass materials. The trick is restraint — glass on the chrome, matte on the content. Here's a before/after.",
             mediaAspect: 1.4, flair: MockFlair(text: "Showcase", tint: .orange)),

    makePost("earth-dolomites", "Sunrise over the Dolomites [OC]",
             sub: earth, author: uLena, kind: .image, score: 21_400, comments: 489, ago: hours(9),
             mediaAspect: 0.78, flair: MockFlair(text: "OC", tint: .green)),

    makePost("prog-cachemiss", "TIL the real cost of a cache miss once you actually measure it",
             sub: prog, author: uNina, kind: .text, score: 3_980, comments: 402, ago: hours(11),
             body: "Rewrote a hot loop to be cache-friendly and it got 6x faster with zero algorithmic change. Locality is a feature. Sharing the flamegraphs and the one-line fix that did most of the work.",
             flair: MockFlair(text: "Article", tint: .purple)),

    makePost("aww-door", "He waited by the door every single day until I got home [OC]",
             sub: aww, author: uRosa, kind: .image, score: 44_900, comments: 712, ago: hours(2),
             mediaAspect: 1.0),

    makePost("apple-foldiphone", "The foldable iPhone hands-on roundup is here",
             sub: apple, author: uMax, kind: .link, score: 12_300, comments: 1_204, ago: hours(4),
             mediaAspect: 1.9, link: "apple.com", flair: MockFlair(text: "Rumor", tint: .blue)),

    makePost("fold-gallery", "Gallery: my favorite fold-optimized home screens",
             sub: foldables, author: uTheo, kind: .gallery, score: 2_410, comments: 96, ago: hours(13),
             mediaAspect: 1.3, galleryCount: 4),

    makePost("swift-observable", "I shipped my first app using only @Observable — a retrospective",
             sub: swift, author: uKenji, kind: .text, score: 1_870, comments: 143, ago: hours(15),
             body: "No ObservableObject, no @Published, no Combine. Just @Observable and @Bindable. The mental model finally feels small. Here's what surprised me, what bit me, and the one place I still reach for a plain struct.",
             flair: MockFlair(text: "Discussion", tint: .orange)),

    makePost("earth-iceland", "Glacier lagoon, Iceland — felt like another planet [OC]",
             sub: earth, author: uLena, kind: .image, score: 18_220, comments: 305, ago: hours(18),
             mediaAspect: 1.5, flair: MockFlair(text: "OC", tint: .green)),

    makePost("prog-terminal", "Show & Tell: I built a tiny terminal renderer in 200 lines",
             sub: prog, author: uMax, kind: .link, score: 2_640, comments: 188, ago: hours(20),
             mediaAspect: 1.9, link: "github.com"),

    makePost("aww-apollo", "Rescued this little guy last week — meet Apollo Jr. 🐾",
             sub: aww, author: uAva, kind: .image, score: 38_700, comments: 524, ago: hours(6),
             mediaAspect: 0.85),

    makePost("apple-ios27", "iOS 27 hidden features megathread — drop yours",
             sub: apple, author: uNina, kind: .text, score: 9_450, comments: 2_106, ago: hours(8),
             body: "Adding them as they're found. Reply with the feature and where it lives in Settings and I'll keep the top post updated.",
             flair: MockFlair(text: "Megathread", tint: .blue)),

    makePost("swift-splitview", "Why does NavigationSplitView collapse differently than I expect?",
             sub: swift, author: uKenji, kind: .text, score: 612, comments: 87, ago: hours(22),
             body: "On a fold I want three columns when open and a clean stack when closed. It mostly works, but the detail selection sometimes vanishes on collapse. What's the canonical way to keep selection alive across the size-class change?",
             flair: MockFlair(text: "Question", tint: .red)),

    makePost("earth-faroe", "Album: a week hiking the Faroe Islands",
             sub: earth, author: uRosa, kind: .gallery, score: 14_900, comments: 233, ago: days(1),
             mediaAspect: 1.4, galleryCount: 5, flair: MockFlair(text: "OC", tint: .green)),

    makePost("prog-dns", "The bug was DNS. It is always DNS.",
             sub: prog, author: uNina, kind: .text, score: 7_330, comments: 311, ago: days(1) + hours(2),
             body: "Three days. A rewrite. A rollback. A war room. Want to know what finally fixed it? Tap to find out, but you already know.",
             flair: MockFlair(text: "War Story", tint: .purple), spoiler: true),

    makePost("fold-hinge", "Hinge longevity after two years of daily folding — AMA",
             sub: foldables, author: uTheo, kind: .text, score: 1_540, comments: 274, ago: days(1) + hours(5),
             body: "200k+ folds, no dust ingress, tiny bit of crease softening. Ask me anything about living with one long-term.",
             flair: MockFlair(text: "AMA", tint: .indigo)),

    makePost("aww-mighty", "Tiny but mighty",
             sub: aww, author: uRosa, kind: .image, score: 26_100, comments: 198, ago: days(1) + hours(8),
             mediaAspect: 1.0),

    makePost("apple-teardown", "Foldable iPhone teardown: the hinge is a genuine marvel",
             sub: apple, author: uMax, kind: .image, score: 5_980, comments: 421, ago: days(1) + hours(11),
             mediaAspect: 1.5, flair: MockFlair(text: "Teardown", tint: .blue)),

    makePost("earth-volcano", "Volcanic eruption up close — maybe got a little too near [OC]",
             sub: earth, author: uLena, kind: .image, score: 33_500, comments: 658, ago: days(2),
             mediaAspect: 1.6, flair: MockFlair(text: "OC", tint: .amber), nsfw: true),

    makePost("prog-monorepo", "Monorepo vs polyrepo in 2027 — what actually changed?",
             sub: prog, author: uKenji, kind: .text, score: 2_180, comments: 396, ago: days(2) + hours(4),
             body: "Build graphs got smarter, remote caching is table stakes, and the tooling finally stopped fighting us. Curious where everyone landed this year and why.",
             flair: MockFlair(text: "Discussion", tint: .purple)),
  ]

  // MARK: Queries

  static func posts(in subredditID: String?) -> [MockPost] {
    guard let subredditID else { return feed }
    return feed.filter { $0.subreddit.id == subredditID }
  }

  static var coverStory: MockPost { feed.first(where: { $0.isPinned }) ?? feed[0] }

  // MARK: Comments

  /// A multi-level comment tree. Varies slightly per post so different posts feel distinct,
  /// while staying fully static and deterministic.
  static func comments(for post: MockPost) -> [MockComment] {
    let op = post.author
    return [
      MockComment(id: "\(post.id)-c1", author: uAva,
                  body: "This is exactly the kind of thing I open the app for. The detail is incredible — saving this.",
                  score: 1_240, createdOffset: hours(2), isOP: false, replies: [
        MockComment(id: "\(post.id)-c1.1", author: op,
                    body: "Thank you! Took way more attempts than I'd like to admit. Happy to share the settings if anyone wants them.",
                    score: 880, createdOffset: hours(2) - mins(40), isOP: true, replies: [
          MockComment(id: "\(post.id)-c1.1.1", author: uMax,
                      body: "Please do — especially curious about how you handled the highlights without blowing them out.",
                      score: 210, createdOffset: hours(1), isOP: false, replies: [
            MockComment(id: "\(post.id)-c1.1.1.1", author: op,
                        body: "Bracketed three exposures and blended by hand. The sky was a full two stops brighter than the foreground.",
                        score: 96, createdOffset: mins(48), isOP: true, replies: [
              MockComment(id: "\(post.id)-c1.1.1.1.1", author: uMax,
                          body: "Legend. That explains the dynamic range. Thanks!",
                          score: 31, createdOffset: mins(30), isOP: false, replies: [])
            ])
          ])
        ]),
        MockComment(id: "\(post.id)-c1.2", author: uNina,
                    body: "Underrated comment. People sleep on how much patience this kind of result takes.",
                    score: 156, createdOffset: hours(1) + mins(20), isOP: false, replies: [])
      ]),

      MockComment(id: "\(post.id)-c2", author: uKenji,
                  body: "Okay but can we talk about how good this looks on a big folding screen? Edge to edge, no chrome in the way.",
                  score: 642, createdOffset: hours(3), isOP: false, replies: [
        MockComment(id: "\(post.id)-c2.1", author: uTheo,
                    body: "This is the whole reason I switched. Browsing and reading at the same time changes everything.",
                    score: 301, createdOffset: hours(2) + mins(30), isOP: false, replies: [
          MockComment(id: "\(post.id)-c2.1.1", author: uLena,
                      body: "Right? My slab phone feels like a peephole now.",
                      score: 88, createdOffset: hours(2), isOP: false, replies: [])
        ])
      ]),

      MockComment(id: "\(post.id)-c3", author: uRosa,
                  body: "Commenting so I can find this again later. No notes. Perfect.",
                  score: 74, createdOffset: hours(4), isOP: false, replies: []),

      MockComment(id: "\(post.id)-c4", author: uNina,
                  body: "Counterpoint, and I say this with love: the second photo is stronger than the first. The composition leads the eye better.",
                  score: 415, createdOffset: hours(5), isOP: false, replies: [
        MockComment(id: "\(post.id)-c4.1", author: uAva,
                    body: "Hard disagree — the first one has the better light. But that's the fun of it.",
                    score: 120, createdOffset: hours(4) + mins(30), isOP: false, replies: [
          MockComment(id: "\(post.id)-c4.1.1", author: uKenji,
                      body: "Both of you are right, which is a very diplomatic way of saying I can't choose.",
                      score: 47, createdOffset: hours(4), isOP: false, replies: [])
        ])
      ]),
    ]
  }

  // MARK: Builders

  private static func hours(_ n: Double) -> TimeInterval { n * 3_600 }
  private static func days(_ n: Double) -> TimeInterval { n * 86_400 }
  private static func mins(_ n: Double) -> TimeInterval { n * 60 }

  private static func makePost(
    _ id: String,
    _ title: String,
    sub: MockSubreddit,
    author: MockUser,
    kind: MockPostKind,
    score: Int,
    comments: Int,
    ago: TimeInterval,
    body: String? = nil,
    mediaAspect: CGFloat? = nil,
    galleryCount: Int = 1,
    link: String? = nil,
    flair: MockFlair? = nil,
    nsfw: Bool = false,
    spoiler: Bool = false,
    pinned: Bool = false
  ) -> MockPost {
    let media: MockMediaSeed?
    switch kind {
    case .text:
      media = nil
    case .image, .video:
      media = MockMediaSeed(seed: id, aspect: mediaAspect ?? 1.5, count: 1)
    case .gallery:
      media = MockMediaSeed(seed: id, aspect: mediaAspect ?? 1.3, count: max(2, galleryCount))
    case .link:
      media = MockMediaSeed(seed: id, aspect: mediaAspect ?? 1.9, count: 1)
    }
    return MockPost(
      id: id, title: title, body: body, author: author, subreddit: sub, kind: kind,
      media: media, linkDomain: link, score: score, upvoteRatio: 0.94,
      commentCount: comments, createdOffset: ago, flair: flair,
      isNSFW: nsfw, isSpoiler: spoiler, isPinned: pinned
    )
  }
}
