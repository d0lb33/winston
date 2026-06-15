//
//  AuroraRoot.swift
//  winston
//
//  Aurora — the shared experience: an adaptive NavigationSplitView (communities
//  sidebar | feed | post+comments). Collapses to a single stack on compact width
//  (fold closed / iPhone), expands to 2–3 panes when wide (fold open / iPad / Stage
//  Manager). The same value-based selections drive both layouts.
//
//  Wired to real data: the sidebar reads the signed-in account's CachedSub
//  subscriptions, the feed paginates real posts, and the detail renders the real
//  post + comment engine. The detail column hosts a NavigationStack bound to the
//  tab's Router so deep links (comment-author profiles, crossposts, pushed feeds)
//  flow through the existing Nav / injectInTabDestinations machinery.
//

import SwiftUI
import Defaults
import CoreData

struct AuroraRoot: View {
  @ObservedObject var router: Router
  /// Optional explicit theme (Design Lab preview). nil → the persisted app theme.
  var themeOverride: AuroraTheme? = nil
  var onClose: (() -> Void)? = nil

  @Default(.auroraThemeID) private var auroraThemeID
  private var theme: AuroraTheme { themeOverride ?? auroraThemeID.theme }

  @FetchRequest private var subs: FetchedResults<CachedSub>

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  /// Drives which single column is shown when the split collapses on a phone, so
  /// selecting a feed/post actually advances sidebar → feed → detail (without this
  /// the selection updates state but the view stays on the sidebar).
  @State private var preferredColumn: NavigationSplitViewColumn = .content
  @State private var selectedSubID: String? = "popular"
  @State private var selectedPostID: String? = nil
  @State private var detailPost: Post? = nil
  @State private var detailHighlightID: String? = nil
  @State private var feedPath: [Router.NavDest] = []
  @State private var sort: SubListingSortOption = .hot
  @State private var model = AuroraFeedModel(subreddit: Subreddit(id: "popular"))

  init(router: Router, themeOverride: AuroraTheme? = nil, onClose: (() -> Void)? = nil) {
    self.router = router
    self.themeOverride = themeOverride
    self.onClose = onClose
    if let cid = Defaults[.GeneralDefSettings].redditCredentialSelectedID {
      _subs = FetchRequest<CachedSub>(
        sortDescriptors: [NSSortDescriptor(key: "display_name", ascending: true)],
        predicate: NSPredicate(format: "winstonCredentialID == %@", cid as CVarArg),
        animation: .default
      )
    } else {
      _subs = FetchRequest<CachedSub>(
        sortDescriptors: [NSSortDescriptor(key: "display_name", ascending: true)],
        animation: .default
      )
    }
  }

  // MARK: - Selection → entity resolution

  private func resolve(_ selection: String?) -> (sub: Subreddit, community: Subreddit?) {
    guard let selection else { return (Subreddit(id: "popular"), nil) }
    if feedsAndSuch.contains(selection) { return (Subreddit(id: selection), nil) }
    if let cached = subs.first(where: { $0.uuid == selection }) {
      let sub = Subreddit(data: SubredditData(entity: cached))
      return (sub, sub)
    }
    return (Subreddit(id: selection), nil)
  }

  /// Title + community derive from the feed the model is ACTUALLY showing, not from
  /// `selectedSubID` — the sidebar List selection is flaky (it clears transiently when
  /// the CachedSub @FetchRequest re-syncs), and deriving display state from it made the
  /// header snap back to Popular. `model.subreddit` is the stable source of truth.
  private var currentCommunity: Subreddit? {
    feedsAndSuch.contains(model.subreddit.id) ? nil : model.subreddit
  }

  private var feedTitle: String {
    model.subreddit.displayTitle
  }

  private var selectedPost: Post? {
    if let selectedPostID, let post = model.post(id: selectedPostID) {
      return post
    }
    return detailPost
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 320)
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.auroraTheme, theme)
    .tint(theme.accent)
    .fontDesign(theme.fontDesign)
    .preferredColorScheme(theme.colorScheme)
    .background { AuroraBackdrop(theme: theme) }
    .toolbarBackground(.hidden, for: .navigationBar)
    .overlay(alignment: .topTrailing) {
      if let onClose {
        DesignLabClose(tint: theme.onGlass) { onClose() }
          .padding(.top, 8)
          .padding(.trailing, 14)
      }
    }
    .diagnosticScreen("aurora.posts")
    .onChange(of: selectedSubID) { _, newID in
      // Ignore transient deselection (the sidebar List clears its selection when the
      // CachedSub @FetchRequest re-syncs); only react to a real new pick.
      guard let newID else { return }
      let sub = resolve(newID).sub
      AppDiagnostics.asyncBreadcrumb("Aurora feed selected", metadata: ["selection": newID, "sub": sub.id])
      model.prepare(for: sub)
      selectedPostID = nil
      detailPost = nil
      detailHighlightID = nil
      feedPath = []
      if !router.fullPath.isEmpty { router.fullPath = [] }
      // Advance to the feed when a community/feed is picked from the sidebar.
      preferredColumn = .content
    }
    .onChange(of: selectedPostID) { _, newID in
      // Advance to the post detail when a card is selected.
      if let newID {
        if let post = model.post(id: newID) {
          detailPost = post
        }
        detailHighlightID = nil
        // A new feed selection resets the detail column to that post's root.
        if !router.fullPath.isEmpty { router.fullPath = [] }
        AppDiagnostics.asyncBreadcrumb("Aurora post selected", metadata: ["post": newID])
        preferredColumn = .detail
      }
    }
    .onChange(of: router.fullPath) { _, path in
      // Any push (comment-author profile, crosspost, a sub/user tapped from a card)
      // advances the collapsed phone layout to the detail column.
      if path.isEmpty {
        if selectedPost == nil {
          preferredColumn = .content
        }
      } else {
        preferredColumn = .detail
      }
    }
  }

  private var contentColumn: some View {
    NavigationStack(path: $feedPath) {
      feedContent
        .injectInTabDestinations(viewControllerHolder: router.navController)
    }
    .navigationSplitViewColumnWidth(min: 360, ideal: 440)
  }

  @ViewBuilder private var feedContent: some View {
    if model.subreddit.id == "saved" {
      AuroraSavedScreen(onPostSelected: selectSavedPost, onCommentSelected: selectSavedComment)
        .diagnosticScreen("aurora.saved")
    } else {
      AuroraFeed(model: model, title: feedTitle, community: currentCommunity,
                 selectedPostID: $selectedPostID, sort: $sort) { destination in
        feedPath.append(destination)
      }
    }
  }

  private var detailColumn: some View {
    NavigationStack(path: $router.fullPath) {
      detailContent
        .injectInTabDestinations(viewControllerHolder: router.navController)
    }
  }

  @ViewBuilder private var detailContent: some View {
    if let selectedPost {
      AuroraPostDetail(post: selectedPost, subreddit: detailSubreddit(for: selectedPost), highlightID: detailHighlightID)
        .id("\(selectedPost.id)-\(detailHighlightID ?? "root")")
        .diagnosticScreen("aurora.post.\(selectedPost.id)")
    } else {
      AuroraDetailPlaceholder()
    }
  }

  private func detailSubreddit(for post: Post) -> Subreddit {
    // Use the post's REAL subreddit, never the feed's pseudo-sub. Posts loaded from
    // Popular/Home carry winstonData.subreddit == the feed ("popular"/"home"), which
    // is wrong for the detail header, permalink, and avatar fetches.
    if let name = post.data?.subreddit, !name.isEmpty {
      return Subreddit(id: name)
    }
    return post.winstonData?.subreddit ?? Subreddit(id: selectedSubID ?? "")
  }

  private func selectSavedPost(_ post: Post) {
    selectedPostID = nil
    detailPost = post
    detailHighlightID = nil
    if !router.fullPath.isEmpty { router.fullPath = [] }
    preferredColumn = .detail
  }

  private func selectSavedComment(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    selectedPostID = nil
    detailPost = Post(id: linkID, subID: subID)
    detailHighlightID = comment.id
    if !router.fullPath.isEmpty { router.fullPath = [] }
    preferredColumn = .detail
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: $selectedSubID) {
      Section {
        feedRow("Home", id: "home", systemImage: "house.fill")
        feedRow("Popular", id: "popular", systemImage: "chart.line.uptrend.xyaxis")
        feedRow("Saved", id: "saved", systemImage: "bookmark.fill")
        // r/all is intentionally omitted: Reddit's feed GraphQL returns a server
        // "internal error" for it (no SDUI feed exists), so there's nothing to show.
      }
      Section("Communities") {
        ForEach(subs.filter { $0.user_is_subscriber && $0.uuid != nil }, id: \.uuid) { sub in
          AuroraSidebarCommunityRow(cachedSub: sub)
          // Tag with a plain String (not String?) so these rows share the fixed
          // feeds' tag type — mixing String and String? tags silently breaks List
          // selection for the inconsistent rows (here, the communities).
          .tag(sub.uuid ?? "")
          .listRowBackground(Color.clear)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .navigationTitle("Aurora")
  }

  private func feedRow(_ label: String, id: String, systemImage: String) -> some View {
    Label(label, systemImage: systemImage)
      .tag(id)
      .listRowBackground(Color.clear)
  }
}

private struct AuroraSidebarCommunityRow: View {
  @ObservedObject var cachedSub: CachedSub
  @Environment(\.auroraTheme) private var theme
  @State private var isFavorited: Bool

  init(cachedSub: CachedSub) {
    self.cachedSub = cachedSub
    self._isFavorited = State(initialValue: cachedSub.user_has_favorited)
  }

  private var data: SubredditData {
    SubredditData(entity: cachedSub)
  }

  private var displayName: String {
    if let name = data.display_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return name
    }
    if let name = cachedSub.display_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return name
    }
    return "subreddit"
  }

  var body: some View {
    HStack(spacing: 10) {
      AuroraSubIcon(name: displayName, iconKit: data.subredditIconKit, size: 26)
      Text("r/\(displayName)")
        .font(.subheadline.weight(.medium))
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(action: favoriteToggle) {
        Image(systemName: isFavorited ? "star.fill" : "star")
          .font(.caption.weight(.semibold))
          .foregroundStyle(isFavorited ? theme.accent : Color.secondary.opacity(0.45))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isFavorited ? "Remove favorite" : "Add favorite")
    }
    .onAppear {
      isFavorited = cachedSub.user_has_favorited
    }
    .onChange(of: cachedSub.user_has_favorited) { _, favorited in
      withAnimation {
        isFavorited = favorited
      }
    }
  }

  private func favoriteToggle() {
    let subreddit = Subreddit(data: data)
    withAnimation {
      isFavorited.toggle()
    }
    subreddit.favoriteToggle(entity: cachedSub) { favorited in
      withAnimation {
        isFavorited = favorited
      }
    }
  }
}

struct AuroraDetailPlaceholder: View {
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "rectangle.split.2x1")
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(theme.accent)
      Text("Pick a post").font(.title3.weight(.semibold))
      Text("Open it here while the feed stays in view — the quiet luxury of the big screen.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Standalone Aurora shell for the Design Lab preview (owns a throwaway router so
/// deep navigation still works inside the full-screen cover).
struct AuroraDesignLabPreview: View {
  let theme: AuroraTheme
  let onClose: () -> Void
  @StateObject private var router = Router(id: "aurora-designlab")
  var body: some View {
    AuroraRoot(router: router, themeOverride: theme, onClose: onClose)
  }
}
