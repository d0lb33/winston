//
//  AuroraRoot.swift
//  winston
//
//  Aurora — the Posts surface. Two shells render one shared `PostsNav`, chosen by the
//  ACTUAL available width (never the device idiom):
//
//  - Compact width (folded foldable, iPhone, narrow split view): one `NavigationStack`
//    with the feed as the root. Home / Popular / Saved / subreddits / saved lists are feed
//    SCOPES picked from a toolbar picker — NOT a collapsed `NavigationSplitView` sidebar
//    column. This is the whole point of the rebuild: the compact path never depends on
//    `preferredCompactColumn` choreography.
//  - Wide width (unfolded foldable, iPad, Stage Manager): one `NavigationSplitView`
//    (scopes sidebar | feed | post). `.regular` is forced into the split's environment so
//    it always shows its columns regardless of the device's reported size class.
//
//  Both shells bind to the same `PostsNav`, so fold/unfold preserves the feed scope, the
//  open post, and the detail path. Feed model + scroll runtime are owned here, above the
//  shell switch, so they survive the swap without writing scroll frames into observed nav.
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

  @FetchRequest private var subs: FetchedResults<CachedSub>

  @State private var sort: SubListingSortOption = .hot
  @State private var model = AuroraFeedModel(subreddit: Subreddit(id: "popular"))
  @State private var feedScrollState = AuroraFeedScrollStateStore()
  @State private var savedListSummaries: [SavedListSummary] = []
  /// The shell's measured width, used to pick the compact vs wide layout.
  @State private var measuredWidth: CGFloat = 0

  init(nav posts: PostsNav, accountID: UUID? = nil, themeOverride: AuroraTheme? = nil, onClose: (() -> Void)? = nil) {
    let launchFeed = DefaultLaunchFeed(settingsValue: Defaults[.BehaviorDefSettings].preferenceDefaultFeed)
    self.posts = posts
    self.accountID = accountID
    self.themeOverride = themeOverride
    self.onClose = onClose
    // Initialise the feed model from the CURRENT scope (the source of truth), not the launch
    // preference — otherwise a scope≠model mismatch makes the first appear fire an extra
    // `model.prepare`, which cancels the feed's in-flight fetch and leaves it stuck loading.
    let initialSub = posts.scope.feedSubredditID.map { Subreddit(id: $0) } ?? launchFeed.initialSubreddit
    _model = State(initialValue: AuroraFeedModel(subreddit: initialSub))
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

  // MARK: - Scope → entity resolution

  /// The `Subreddit` the feed model should load for a post-feed scope. Resolves a
  /// `.subreddit(id:)` uuid to its cached community (for the real display name / icon).
  private func subreddit(for scope: FeedScope) -> Subreddit {
    switch scope {
    case .home: return Subreddit(id: "home")
    case .popular: return Subreddit(id: "popular")
    case .saved: return Subreddit(id: "saved")
    case .subreddit(let id):
      if let cached = subs.first(where: { $0.uuid == id }) {
        return Subreddit(data: SubredditData(entity: cached))
      }
      return Subreddit(id: id)
    case .savedList, .savedListsOverview:
      return model.subreddit
    }
  }

  /// The real community backing the feed header (nil for Home/Popular). Derived from the
  /// feed the model is ACTUALLY showing — the stable source of truth.
  private var currentCommunity: Subreddit? {
    feedsAndSuch.contains(model.subreddit.id) ? nil : model.subreddit
  }

  private var feedTitle: String { model.subreddit.displayTitle }

  private var selectedPost: Post? {
    if let id = posts.selectedPostID, let post = model.post(id: id) { return post }
    return posts.detailPost
  }

  /// At or above this width the wide three-column split is used; below it, the compact
  /// single-column stack. Width-driven, not idiom-driven, so a folded foldable / iPad-mini
  /// portrait / narrow split-view get the compact shell and an unfolded / landscape / large
  /// window gets the wide shell.
  static let expandedLayoutMinWidth: CGFloat = 820

  var body: some View {
    let expanded = measuredWidth >= Self.expandedLayoutMinWidth

    shell(expanded: expanded)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
      .auroraShellChrome(theme: theme)
      .toolbarBackground(.hidden, for: .navigationBar)
      .overlay(alignment: .topTrailing) { closeButton }
      .diagnosticScreen("aurora.posts")
      .onAppear {
        applyLayout(expanded: expanded)
        reloadSavedListSummaries()
        syncModelToScope()
      }
      .onChange(of: expanded) { _, isExpanded in applyLayout(expanded: isExpanded) }
      .onChange(of: posts.scope) { _, _ in handleScopeChange() }
      .onChange(of: posts.feedScrollResetRequest) { _, _ in feedScrollState.reset() }
      .onChange(of: accountID) { _, _ in
        resetAccountScopedState()
        reloadSavedListSummaries()
      }
      .onChange(of: posts.selectedPostID) { _, newID in
        // Promote a feed-row selection to the open post (wide highlight + compact push).
        guard let newID, let post = model.post(id: newID) else { return }
        posts.selectFeedPost(post)
        AppDiagnostics.asyncBreadcrumb("Aurora post selected", metadata: ["post": newID])
      }
      .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
        reloadSavedListSummaries()
      }
  }

  @ViewBuilder private func shell(expanded: Bool) -> some View {
    if expanded { wideShell } else { compactShell }
  }

  @ViewBuilder private var closeButton: some View {
    if let onClose {
      DesignLabClose(tint: theme.onGlass) { onClose() }
        .padding(.top, 8)
        .padding(.trailing, 14)
    }
  }

  // MARK: - Compact shell (feed root + scope picker; no NavigationSplitView)

  private var compactShell: some View {
    @Bindable var posts = posts

    return NavigationStack(path: $posts.compactPath) {
      AuroraCompactRootList(
        favoriteLists: savedListSummaries,
        favoriteCommunities: favoriteCommunities,
        subscribedCommunities: subscribedCommunities,
        onSelect: { posts.presentScopeFeed($0) }
      )
      .compactPostsDestinations(posts) {
        feedContent(selectedPostID: $posts.selectedPostID)
      }
    }
  }

  // MARK: - Wide shell (scopes sidebar | feed | post)

  private var wideShell: some View {
    @Bindable var posts = posts

    return NavigationSplitView {
      scopeSidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 320)
    } content: {
      NavigationStack(path: $posts.contentPath) {
        feedContent(selectedPostID: $posts.selectedPostID)
          .redditNavigation(posts, origin: .content)
          .redditDestinations(posts, origin: .content)
      }
      .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    } detail: {
      NavigationStack(path: $posts.detailPath) {
        detailContent
          .redditNavigation(posts, origin: .detail)
          .redditDestinations(posts, origin: .detail)
      }
    }
    .navigationSplitViewStyle(.balanced)
    // Force the split to stay expanded (show its columns) regardless of the device's
    // reported size class — the compact case is handled by the separate `compactShell`.
    .environment(\.horizontalSizeClass, .regular)
  }

  // MARK: - Shared feed surface (scope-driven)

  @ViewBuilder private func feedContent(selectedPostID: Binding<String?>) -> some View {
    @Bindable var posts = posts
    switch posts.scope {
    case .savedListsOverview:
      SavedListsOverviewScreen(
        mode: .manage,
        onListSelected: { list in posts.scope = .savedList(id: list.id) },
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedLists")
      .onAppear { posts.updateContentCanScrollToTop(false) }
    case .savedList(let id):
      SavedListDetailScreen(
        listID: id,
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedList.\(id.uuidString)")
      .onAppear { posts.updateContentCanScrollToTop(false) }
    case .saved:
      AuroraSavedScreen(onPostSelected: selectSavedPost, onCommentSelected: selectSavedComment)
        .diagnosticScreen("aurora.saved")
        .onAppear { posts.updateContentCanScrollToTop(false) }
    case .home, .popular, .subreddit:
      AuroraFeed(model: model, title: feedTitle, community: currentCommunity,
                 scrollState: feedScrollState,
                 selectedPostID: selectedPostID,
                 sort: $sort,
                 scrollToTopRequest: posts.contentScrollToTopRequest,
                 onScrollStateChanged: { canScroll in posts.updateContentCanScrollToTop(canScroll) }) { destination in
        posts.navigate(destination, from: .content)
      }
    }
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
    // Use the post's REAL subreddit, never the feed's pseudo-sub.
    if let name = post.data?.subreddit, !name.isEmpty {
      return Subreddit(id: name)
    }
    return post.winstonData?.subreddit ?? Subreddit(id: posts.scope.feedSubredditID ?? "")
  }

  // MARK: - Scope changes / account bridges

  private func handleScopeChange() {
    posts.resetContentAndDetail()
    feedScrollState.reset()
    syncModelToScope()
  }

  /// Point the feed model at the current scope (no-op for the saved-lists screens, which
  /// are not post feeds and render independently of the model).
  private func syncModelToScope() {
    guard posts.scope.isPostFeed else { return }
    let sub = subreddit(for: posts.scope)
    if sub.id != model.subreddit.id {
      AppDiagnostics.asyncBreadcrumb("Aurora feed selected", metadata: ["scope": posts.scope.token, "sub": sub.id])
      model.prepare(for: sub)
    }
  }

  private func resetAccountScopedState() {
    let launchFeed = DefaultLaunchFeed(settingsValue: Defaults[.BehaviorDefSettings].preferenceDefaultFeed)
    posts.reset(to: launchFeed)
    feedScrollState.reset()
    model.prepareForAccountSwitch(defaultSubreddit: launchFeed.initialSubreddit)
    sort = .hot
  }

  private func applyLayout(expanded: Bool) {
    posts.updateInteractionLayout(expanded ? .regular : .compact)
    // The wide split always shows a feed column, so mark the feed presented — folding
    // wide→compact then lands on that feed (preserving its scroll) instead of the root list.
    // Compact launch leaves the flag false, so a cold iPhone start shows the root list.
    if expanded { posts.compactFeedPresented = true }
  }

  private func selectSavedPost(_ post: Post) {
    posts.openPostInDetail(post)
  }

  private func selectSavedComment(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    posts.openPostInDetail(Post(id: linkID, subID: subID), highlightID: comment.id)
  }

  // MARK: - Communities

  private var subscribedCommunities: [CachedSub] {
    sortedSidebarCommunities(subs.filter { $0.user_is_subscriber && $0.uuid != nil })
  }

  private var favoriteCommunities: [CachedSub] {
    subscribedCommunities.filter(\.user_has_favorited)
  }

  // MARK: - Wide sidebar

  /// The selection binding ignores transient nil (the `CachedSub` `@FetchRequest` clears the
  /// `List` selection when it re-syncs); only a real new pick changes the scope. Routes through
  /// `presentScopeFeed` so a wide-sidebar pick also marks the feed presented — folding
  /// wide→compact then lands on that feed (not the root list) and preserves its scroll.
  private var scopeSelection: Binding<FeedScope?> {
    Binding(get: { posts.scope }, set: { if let scope = $0 { posts.presentScopeFeed(scope) } })
  }

  private var scopeSidebar: some View {
    List(selection: scopeSelection) {
      Section {
        Color.clear
          .frame(height: 44)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
          .accessibilityHidden(true)
        scopeRow("Home", scope: .home, systemImage: "house.fill")
        scopeRow("Popular", scope: .popular, systemImage: "chart.line.uptrend.xyaxis")
        scopeRow("Saved", scope: .saved, systemImage: "bookmark.fill")
        scopeRow("Saved Lists", scope: .savedListsOverview, systemImage: "list.bullet.rectangle")
      }
      if !savedListSummaries.isEmpty {
        Section("Favorite Lists") {
          ForEach(savedListSummaries) { list in
            savedListScopeRow(list)
          }
        }
      }
      if !favoriteCommunities.isEmpty {
        Section("Favorites") {
          ForEach(favoriteCommunities, id: \.uuid) { sub in
            AuroraSidebarCommunityRow(cachedSub: sub)
              .tag(FeedScope.subreddit(id: sub.uuid ?? ""))
              .listRowBackground(Color.clear)
          }
        }
      }
      Section("Communities") {
        ForEach(subscribedCommunities, id: \.uuid) { sub in
          AuroraSidebarCommunityRow(cachedSub: sub)
            .tag(FeedScope.subreddit(id: sub.uuid ?? ""))
            .listRowBackground(Color.clear)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .navigationTitle("Aurora")
    .refreshable {
      await refreshSubscriptions()
    }
  }

  private func scopeRow(_ label: String, scope: FeedScope, systemImage: String) -> some View {
    Label(label, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .tag(scope)
      .listRowBackground(Color.clear)
  }

  private func savedListScopeRow(_ list: SavedListSummary) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(list.name).lineLimit(1)
        Text("\(list.count) items").font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "folder.fill")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(FeedScope.savedList(id: list.id))
    .listRowBackground(Color.clear)
  }


  // MARK: - Helpers

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

/// The COMPACT (iPhone) Posts "home" — a full-screen scope/subreddit list that is the
/// `NavigationStack` root. Tapping a row pushes that scope's feed (Apollo style). Mirrors the
/// wide `scopeSidebar` sections, but uses tap-to-push (`onSelect`) instead of `List(selection:)`.
private struct AuroraCompactRootList: View {
  let favoriteLists: [SavedListSummary]
  let favoriteCommunities: [CachedSub]
  let subscribedCommunities: [CachedSub]
  let onSelect: (FeedScope) -> Void
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    List {
      Section {
        scopeRow("Home", scope: .home, systemImage: "house.fill")
        scopeRow("Popular", scope: .popular, systemImage: "chart.line.uptrend.xyaxis")
        scopeRow("Saved", scope: .saved, systemImage: "bookmark.fill")
        scopeRow("Saved Lists", scope: .savedListsOverview, systemImage: "list.bullet.rectangle")
      }
      if !favoriteLists.isEmpty {
        Section("Favorite Lists") {
          ForEach(favoriteLists) { list in
            Button { onSelect(.savedList(id: list.id)) } label: {
              rowChrome {
                Label {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(list.name).lineLimit(1)
                    Text("\(list.count) items").font(.caption).foregroundStyle(.secondary)
                  }
                } icon: { Image(systemName: "folder.fill") }
              }
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
          }
        }
      }
      if !favoriteCommunities.isEmpty {
        Section("Favorites") {
          ForEach(favoriteCommunities, id: \.uuid) { sub in communityRow(sub) }
        }
      }
      Section("Communities") {
        ForEach(subscribedCommunities, id: \.uuid) { sub in communityRow(sub) }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .navigationTitle("Subreddits")
    .diagnosticScreen("aurora.compactRoot")
  }

  private func scopeRow(_ label: String, scope: FeedScope, systemImage: String) -> some View {
    Button { onSelect(scope) } label: {
      rowChrome { Label(label, systemImage: systemImage) }
    }
    .buttonStyle(.plain)
    .listRowBackground(Color.clear)
  }

  private func communityRow(_ sub: CachedSub) -> some View {
    // `AuroraSidebarCommunityRow` already carries its own trailing favorite star, so no chevron.
    Button { onSelect(.subreddit(id: sub.uuid ?? "")) } label: {
      AuroraSidebarCommunityRow(cachedSub: sub)
    }
    .buttonStyle(.plain)
    .listRowBackground(Color.clear)
  }

  /// Adds a trailing disclosure chevron + full-width hit area to signal "tap to open".
  private func rowChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack {
      content()
      Spacer(minLength: 8)
      Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
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

/// Standalone Aurora shell for the Design Lab preview (owns a throwaway PostsNav so it is
/// isolated from the live Posts tab).
struct AuroraDesignLabPreview: View {
  let theme: AuroraTheme
  let onClose: () -> Void
  @State private var posts = PostsNav()
  var body: some View {
    AuroraRoot(nav: posts, themeOverride: theme, onClose: onClose)
  }
}
