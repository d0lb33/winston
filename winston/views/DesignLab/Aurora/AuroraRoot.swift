//
//  AuroraRoot.swift
//  winston
//
//  Aurora — the shared experience: an adaptive NavigationSplitView (communities
//  sidebar | feed | post+comments). Collapses to a single stack on compact width
//  (fold closed / iPhone), expands to 2–3 panes when wide (fold open / iPad / Stage
//  Manager). The same value-based selections drive both layouts.
//
//  Navigation rebuild: the surface's entire navigation state lives in one `PostsNav`
//  (`@State`, owned here). The detail stack is `posts.detailPath` — owned in the model,
//  not an external `Router.fullPath` — so there is nothing to reconcile across
//  size-class transitions; `NavigationSplitView` re-renders straight from `posts` on
//  resize/fold. `preferredCompactColumn` is the single framework-blessed knob for which
//  column the collapsed layout shows; the framework moves it back on the system back
//  button, and selecting a post moves it forward.
//
//  Legacy deep links (`Nav.to`, shortcuts, URL opens) still arrive via the tab `Router`
//  (`contextualDestination` / `fullPath`); this view observes that Router as a write-only
//  inbox and translates anything that lands there into `posts`. That bridge is removed
//  when `Router` is finally deleted.
//

import SwiftUI
import Defaults
import CoreData

struct AuroraRoot: View {
  let posts: PostsNav
  let accountID: UUID?
  /// Optional explicit theme (Design Lab preview). nil → the persisted app theme.
  var themeOverride: AuroraTheme? = nil
  var onClose: (() -> Void)? = nil

  @Default(.auroraThemeID) private var auroraThemeID
  private var theme: AuroraTheme { themeOverride ?? auroraThemeID.theme }

  @Environment(\.horizontalSizeClass) private var hSize

  @FetchRequest private var subs: FetchedResults<CachedSub>

  @State private var sort: SubListingSortOption = .hot
  @State private var model = AuroraFeedModel(subreddit: Subreddit(id: "popular"))
  @State private var savedListSummaries: [SavedListSummary] = []

  init(nav posts: PostsNav, accountID: UUID? = nil, themeOverride: AuroraTheme? = nil, onClose: (() -> Void)? = nil) {
    let launchFeed = DefaultLaunchFeed(settingsValue: Defaults[.BehaviorDefSettings].preferenceDefaultFeed)
    self.posts = posts
    self.accountID = accountID
    self.themeOverride = themeOverride
    self.onClose = onClose
    _model = State(initialValue: AuroraFeedModel(subreddit: launchFeed.initialSubreddit))
    if let cid = accountID {
      _subs = FetchRequest<CachedSub>(
        sortDescriptors: [NSSortDescriptor(key: "display_name", ascending: true)],
        predicate: NSPredicate(format: "winstonCredentialID == %@", cid as CVarArg),
        animation: .default
      )
    } else {
      _subs = FetchRequest<CachedSub>(
        sortDescriptors: [NSSortDescriptor(key: "display_name", ascending: true)],
        predicate: NSPredicate(value: false),
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
  /// `posts.community` — the sidebar List selection is flaky (it clears transiently when
  /// the CachedSub @FetchRequest re-syncs), and deriving display state from it made the
  /// header snap back to Popular. `model.subreddit` is the stable source of truth.
  private var currentCommunity: Subreddit? {
    feedsAndSuch.contains(model.subreddit.id) ? nil : model.subreddit
  }

  private var feedTitle: String {
    model.subreddit.displayTitle
  }

  private var selectedPost: Post? {
    if let id = posts.selectedPostID, let post = model.post(id: id) {
      return post
    }
    return posts.detailPost
  }

  var body: some View {
    @Bindable var posts = posts

    NavigationSplitView(preferredCompactColumn: $posts.preferredColumn) {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 320)
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.balanced)
    .auroraShellChrome(theme: theme)
    .toolbarBackground(.hidden, for: .navigationBar)
    .overlay(alignment: .topTrailing) {
      if let onClose {
        DesignLabClose(tint: theme.onGlass) { onClose() }
          .padding(.top, 8)
          .padding(.trailing, 14)
      }
    }
    .diagnosticScreen("aurora.posts")
    .onAppear {
      updateInteractionLayout()
      reloadSavedListSummaries()
    }
    .onChange(of: hSize) { _, _ in
      updateInteractionLayout()
    }
    .onChange(of: posts.community) { _, newID in
      // Ignore transient deselection (the sidebar List clears its selection when the
      // CachedSub @FetchRequest re-syncs); only react to a real new pick.
      guard let newID else { return }
      if newID == SavedListsRoute.overviewID || SavedListsRoute.listID(from: newID) != nil {
        posts.resetContentAndDetail()
        return
      }
      let sub = resolve(newID).sub
      AppDiagnostics.asyncBreadcrumb("Aurora feed selected", metadata: ["selection": newID, "sub": sub.id])
      model.prepare(for: sub)
      posts.resetContentAndDetail()
    }
    .onChange(of: accountID) { _, _ in
      resetAccountScopedState()
      reloadSavedListSummaries()
    }
    .onChange(of: posts.selectedPostID) { _, newID in
      // Advance to the post detail when a card is selected (regular width).
      guard let newID, let post = model.post(id: newID) else { return }
      posts.selectFeedPost(post)
      AppDiagnostics.asyncBreadcrumb("Aurora post selected", metadata: ["post": newID])
    }
    .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
      reloadSavedListSummaries()
    }
  }

  // MARK: - Account / external navigation bridges

  private func resetAccountScopedState() {
    resetToLaunchFeed()
    sort = .hot
  }

  private func resetToLaunchFeed() {
    let launchFeed = DefaultLaunchFeed(settingsValue: Defaults[.BehaviorDefSettings].preferenceDefaultFeed)
    posts.reset(to: launchFeed)
    model.prepareForAccountSwitch(defaultSubreddit: launchFeed.initialSubreddit)
  }

  private func updateInteractionLayout() {
    posts.updateInteractionLayout(hSize == .compact ? .compact : .regular)
  }

  // MARK: - Columns

  private var contentColumn: some View {
    @Bindable var posts = posts

    return NavigationStack(path: $posts.contentPath) {
      feedContent(selectedPostID: $posts.selectedPostID)
        .redditNavigation(posts, origin: .content)
        .redditDestinations(posts, origin: .content)
    }
    .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    .onAppear { posts.updateRenderedActiveColumn(.content) }
  }

  @ViewBuilder private func feedContent(selectedPostID: Binding<String?>) -> some View {
    @Bindable var posts = posts

    if posts.community == SavedListsRoute.overviewID {
      SavedListsOverviewScreen(
        mode: .manage,
        onListSelected: { list in posts.community = SavedListsRoute.id(for: list.id) },
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedLists")
      .onAppear { posts.updateContentCanScrollToTop(false) }
    } else if let listID = SavedListsRoute.listID(from: posts.community) {
      SavedListDetailScreen(
        listID: listID,
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedList.\(listID.uuidString)")
      .onAppear { posts.updateContentCanScrollToTop(false) }
    } else if model.subreddit.id == "saved" {
      AuroraSavedScreen(onPostSelected: selectSavedPost, onCommentSelected: selectSavedComment)
        .diagnosticScreen("aurora.saved")
        .onAppear { posts.updateContentCanScrollToTop(false) }
    } else {
      AuroraFeed(model: model, title: feedTitle, community: currentCommunity,
                 selectedPostID: selectedPostID,
                 scrollPositionID: $posts.feedScrollPositionID,
                 sort: $sort,
                 scrollToTopRequest: posts.contentScrollToTopRequest,
                 onScrollStateChanged: { canScroll in posts.updateContentCanScrollToTop(canScroll) }) { destination in
        posts.navigate(destination, from: .content)
      }
    }
  }

  private var detailColumn: some View {
    @Bindable var posts = posts

    return NavigationStack(path: $posts.detailPath) {
      detailContent
        .redditNavigation(posts, origin: .detail)
        .redditDestinations(posts, origin: .detail)
    }
    .onAppear { posts.updateRenderedActiveColumn(.detail) }
  }

  @ViewBuilder private var detailContent: some View {
    if let selectedPost {
      AuroraPostDetail(
        post: selectedPost,
        subreddit: detailSubreddit(for: selectedPost),
        highlightID: posts.detailHighlightID,
        scrollToTopRequest: posts.detailScrollToTopRequest,
        onScrollStateChanged: { canScroll in posts.updateDetailCanScrollToTop(canScroll) }
      )
        .id("\(selectedPost.id)-\(posts.detailHighlightID ?? "root")")
        .diagnosticScreen("aurora.post.\(selectedPost.id)")
    } else {
      AuroraDetailPlaceholder()
        .onAppear { posts.updateDetailCanScrollToTop(false) }
    }
  }

  private func detailSubreddit(for post: Post) -> Subreddit {
    // Use the post's REAL subreddit, never the feed's pseudo-sub. Posts loaded from
    // Popular/Home carry winstonData.subreddit == the feed ("popular"/"home"), which
    // is wrong for the detail header, permalink, and avatar fetches.
    if let name = post.data?.subreddit, !name.isEmpty {
      return Subreddit(id: name)
    }
    return post.winstonData?.subreddit ?? Subreddit(id: posts.community ?? "")
  }

  private func selectSavedPost(_ post: Post) {
    posts.openPostInDetail(post)
  }

  private func selectSavedComment(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    posts.openPostInDetail(Post(id: linkID, subID: subID), highlightID: comment.id)
  }

  // MARK: - Sidebar

  private var subscribedCommunities: [CachedSub] {
    sortedSidebarCommunities(subs.filter { $0.user_is_subscriber && $0.uuid != nil })
  }

  private var favoriteCommunities: [CachedSub] {
    subscribedCommunities.filter(\.user_has_favorited)
  }

  private var sidebar: some View {
    @Bindable var posts = posts

    return List(selection: $posts.community) {
      Section {
        Color.clear
          .frame(height: 44)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
          .accessibilityHidden(true)
        feedRow("Home", id: "home", systemImage: "house.fill")
        feedRow("Popular", id: "popular", systemImage: "chart.line.uptrend.xyaxis")
        feedRow("Saved", id: "saved", systemImage: "bookmark.fill")
        feedRow("Saved Lists", id: SavedListsRoute.overviewID, systemImage: "list.bullet.rectangle")
        // r/all is intentionally omitted: Reddit's feed GraphQL returns a server
        // "internal error" for it (no SDUI feed exists), so there's nothing to show.
      }
      if !savedListSummaries.isEmpty {
        Section("Favorite Lists") {
          ForEach(savedListSummaries) { list in
            savedListSidebarRow(list)
          }
        }
      }
      if !favoriteCommunities.isEmpty {
        Section("Favorites") {
          ForEach(favoriteCommunities, id: \.uuid) { sub in
            AuroraSidebarCommunityRow(cachedSub: sub)
              .tag(sub.uuid ?? "")
              .listRowBackground(Color.clear)
          }
        }
      }
      Section("Communities") {
        ForEach(subscribedCommunities, id: \.uuid) { sub in
          AuroraSidebarCommunityRow(cachedSub: sub)
            .tag(sub.uuid ?? "")
            .listRowBackground(Color.clear)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .navigationTitle("Aurora")
    .onAppear { posts.updateRenderedActiveColumn(.sidebar) }
    .refreshable {
      await refreshSubscriptions()
    }
  }

  private func sortedSidebarCommunities(_ communities: [CachedSub]) -> [CachedSub] {
    communities.sorted { lhs, rhs in
      AuroraSidebarCommunitySort.precedes(
        lhsDisplayName: lhs.display_name,
        lhsName: lhs.name,
        lhsUUID: lhs.uuid,
        rhsDisplayName: rhs.display_name,
        rhsName: rhs.name,
        rhsUUID: rhs.uuid
      )
    }
  }

  private func refreshSubscriptions() async {
    guard let accountID else { return }
    await RedditWire.shared.fetchSubs(for: accountID)
    reloadSavedListSummaries()
  }

  private func feedRow(_ label: String, id: String, systemImage: String) -> some View {
    Label(label, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .tag(id)
      .listRowBackground(Color.clear)
  }

  private func savedListSidebarRow(_ list: SavedListSummary) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(list.name)
          .lineLimit(1)
        Text("\(list.count) items")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "folder.fill")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(SavedListsRoute.id(for: list.id))
    .listRowBackground(Color.clear)
  }

  private func reloadSavedListSummaries() {
    savedListSummaries = SavedListsStore.shared.favoriteLists()
  }

}

enum AuroraSidebarCommunitySort {
  static func sortKey(displayName: String?, name: String?, uuid: String?) -> String {
    let rawValue = [displayName, name, uuid]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
    let hasSubredditPrefix = rawValue.range(of: "r/", options: [.anchored, .caseInsensitive]) != nil
    let unprefixed = hasSubredditPrefix ? String(rawValue.dropFirst(2)) : rawValue
    return unprefixed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  static func precedes(
    lhsDisplayName: String?,
    lhsName: String?,
    lhsUUID: String?,
    rhsDisplayName: String?,
    rhsName: String?,
    rhsUUID: String?
  ) -> Bool {
    let lhsKey = sortKey(displayName: lhsDisplayName, name: lhsName, uuid: lhsUUID)
    let rhsKey = sortKey(displayName: rhsDisplayName, name: rhsName, uuid: rhsUUID)
    if lhsKey == rhsKey {
      return (lhsUUID ?? "") < (rhsUUID ?? "")
    }
    return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
  }
}

extension View {
  func auroraMeasuredColumn(maxWidth: CGFloat = 1300) -> some View {
    self
      .frame(maxWidth: maxWidth)
      .frame(maxWidth: .infinity)
  }

  func auroraShellChrome(theme: AuroraTheme) -> some View {
    self
      .environment(\.auroraTheme, theme)
      .tint(theme.accent)
      .fontDesign(theme.fontDesign)
      .preferredColorScheme(theme.colorScheme)
      .background { AuroraBackdrop(theme: theme) }
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
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

/// Standalone Aurora shell for the Design Lab preview (owns a throwaway router so deep
/// navigation still works inside the full-screen cover; the rebuilt AuroraRoot owns its
/// own PostsNav, so the preview is automatically isolated from the live Posts tab).
struct AuroraDesignLabPreview: View {
  let theme: AuroraTheme
  let onClose: () -> Void
  @State private var posts = PostsNav()
  var body: some View {
    AuroraRoot(nav: posts, themeOverride: theme, onClose: onClose)
  }
}
