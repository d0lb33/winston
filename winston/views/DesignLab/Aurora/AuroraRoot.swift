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
  let accountID: UUID?
  /// Optional explicit theme (Design Lab preview). nil → the persisted app theme.
  var themeOverride: AuroraTheme? = nil
  var onClose: (() -> Void)? = nil

  @Default(.auroraThemeID) private var auroraThemeID
  private var theme: AuroraTheme { themeOverride ?? auroraThemeID.theme }

  @FetchRequest private var subs: FetchedResults<CachedSub>

  /// Shared content/detail navigation state. Drives which single column is shown
  /// when the split collapses and keeps content-origin links out of the detail stack.
  @State private var navigation = RedditSplitNavigationModel(contentColumn: .content)
  @State private var selectedSubID: String? = "popular"
  @State private var sort: SubListingSortOption = .hot
  @State private var model = AuroraFeedModel(subreddit: Subreddit(id: "popular"))
  @State private var savedListSummaries: [SavedListSummary] = []

  init(router: Router, accountID: UUID? = nil, themeOverride: AuroraTheme? = nil, onClose: (() -> Void)? = nil) {
    self.router = router
    self.accountID = accountID
    self.themeOverride = themeOverride
    self.onClose = onClose
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
    if let selectedPostID = navigation.selectedPostID, let post = model.post(id: selectedPostID) {
      return post
    }
    return navigation.detailPost
  }

  var body: some View {
    @Bindable var navigation = navigation

    NavigationSplitView(columnVisibility: $navigation.columnVisibility, preferredCompactColumn: $navigation.preferredColumn) {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 320)
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.balanced)
    .redditForwardNavigationGesture(navigation: navigation) {
      contentColumn
    }
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
      navigation.attach(router: router)
      _ = navigation.absorbRootNavigationPathIfNeeded(router: router)
      reloadSavedListSummaries()
      consumeContextualDestinationIfNeeded()
    }
    .onChange(of: selectedSubID) { _, newID in
      // Ignore transient deselection (the sidebar List clears its selection when the
      // CachedSub @FetchRequest re-syncs); only react to a real new pick.
      guard let newID else { return }
      if newID == SavedListsRoute.overviewID || SavedListsRoute.listID(from: newID) != nil {
        navigation.resetContentPathAndDetail()
        return
      }
      let sub = resolve(newID).sub
      AppDiagnostics.asyncBreadcrumb("Aurora feed selected", metadata: ["selection": newID, "sub": sub.id])
      model.prepare(for: sub)
      navigation.resetContentPathAndDetail()
      // Advance to the feed when a community/feed is picked from the sidebar.
    }
    .onChange(of: accountID) { _, _ in
      resetAccountScopedState()
      reloadSavedListSummaries()
    }
    .onChange(of: router.contextualDestination) { _, _ in
      consumeContextualDestinationIfNeeded()
    }
    .onChange(of: navigation.selectedPostID) { _, newID in
      // Advance to the post detail when a card is selected.
      if let newID {
        if let post = model.post(id: newID) {
          navigation.selectFeedPost(post)
        }
        AppDiagnostics.asyncBreadcrumb("Aurora post selected", metadata: ["post": newID])
      }
    }
    .onChange(of: router.fullPath) { oldPath, path in
      navigation.recordRouterPathChange(from: oldPath, to: path)
      if navigation.absorbRootNavigationPathIfNeeded(router: router) {
        return
      }
      // Any push (comment-author profile, crosspost, a sub/user tapped from a card)
      // advances the collapsed phone layout to the detail column.
      if path.isEmpty {
        if selectedPost == nil {
          navigation.focusContent()
        }
      } else {
        navigation.focusDetail()
      }
    }
    .onChange(of: navigation.preferredColumn) { oldColumn, newColumn in
      navigation.recordPreferredColumnChange(from: oldColumn, to: newColumn)
    }
    .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
      reloadSavedListSummaries()
    }
  }

  private func resetAccountScopedState() {
    selectedSubID = "popular"
    navigation.resetContentPathAndDetail()
    sort = .hot
    model.prepareForAccountSwitch(defaultSubreddit: Subreddit(id: "popular"))
  }

  private func consumeContextualDestinationIfNeeded() {
    guard let destination = router.contextualDestination else { return }
    router.contextualDestination = nil
    openContextualDestination(destination)
  }

  private func openContextualDestination(_ destination: Router.NavDest) {
    promoteLeadingPostPathToDetailIfNeeded()

    switch navigation.postDetail(from: destination) {
    case .some(let detail):
      openContextualPost(detail.post, highlightID: detail.highlightID)
    case .none:
      openContextualNonPost(destination)
    }
  }

  private func openContextualPost(_ post: Post, highlightID: String?) {
    let destination: Router.NavDest
    if let highlightID {
      destination = .reddit(.postHighlighted(post, highlightID))
    } else {
      destination = .reddit(.post(post))
    }

    if selectedPost != nil || !router.fullPath.isEmpty {
      navigation.navigate(destination, from: .detail)
    } else if !navigation.contentPath.isEmpty {
      navigation.clearForwardHistoryForNewBranch()
      navigation.contentPath.append(destination)
      navigation.focusContent()
    } else {
      navigation.openPostInDetail(post, highlightID: highlightID)
    }
  }

  private func openContextualNonPost(_ destination: Router.NavDest) {
    if case .reddit(.subFeed(let subreddit)) = destination, feedsAndSuch.contains(subreddit.id) {
      selectedSubID = subreddit.id
      navigation.focusContent()
      return
    }

    if selectedPost != nil || !router.fullPath.isEmpty {
      navigation.navigate(destination, from: .detail)
    } else {
      navigation.clearForwardHistoryForNewBranch()
      navigation.contentPath.append(destination)
      navigation.focusContent()
    }
  }

  private func promoteLeadingPostPathToDetailIfNeeded() {
    guard selectedPost == nil,
          let first = router.fullPath.first,
          let detail = navigation.postDetail(from: first)
    else { return }

    navigation.detailPost = detail.post
    navigation.detailHighlightID = detail.highlightID
    navigation.replaceRouterPathWithoutForwardRecording(Array(router.fullPath.dropFirst()))
    navigation.focusDetail()
  }

  private var contentColumn: some View {
    @Bindable var navigation = navigation

    return NavigationStack(path: $navigation.contentPath) {
      feedContent
        .injectInTabDestinations(viewControllerHolder: router.navController)
        .redditNavigation(navigation, origin: .content)
    }
    .navigationSplitViewColumnWidth(min: 360, ideal: 440)
  }

  @ViewBuilder private var feedContent: some View {
    if selectedSubID == SavedListsRoute.overviewID {
      SavedListsOverviewScreen(
        mode: .manage,
        onListSelected: { list in selectedSubID = SavedListsRoute.id(for: list.id) },
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedLists")
    } else if let listID = SavedListsRoute.listID(from: selectedSubID) {
      SavedListDetailScreen(
        listID: listID,
        onPostSelected: selectSavedPost,
        onCommentSelected: selectSavedComment
      )
      .diagnosticScreen("aurora.savedList.\(listID.uuidString)")
    } else if model.subreddit.id == "saved" {
      AuroraSavedScreen(onPostSelected: selectSavedPost, onCommentSelected: selectSavedComment)
        .diagnosticScreen("aurora.saved")
    } else {
      AuroraFeed(model: model, title: feedTitle, community: currentCommunity,
                 selectedPostID: $navigation.selectedPostID, sort: $sort) { destination in
        navigation.navigate(destination, from: .content)
      }
    }
  }

  private var detailColumn: some View {
    NavigationStack(path: $router.fullPath) {
      detailContent
        .injectInTabDestinations(viewControllerHolder: router.navController)
        .redditNavigation(navigation, origin: .detail)
    }
  }

  @ViewBuilder private var detailContent: some View {
    if let selectedPost {
      AuroraPostDetail(post: selectedPost, subreddit: detailSubreddit(for: selectedPost), highlightID: navigation.detailHighlightID)
        .id("\(selectedPost.id)-\(navigation.detailHighlightID ?? "root")")
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
    navigation.openPostInDetail(post)
  }

  private func selectSavedComment(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    navigation.openPostInDetail(Post(id: linkID, subID: subID), highlightID: comment.id)
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: $selectedSubID) {
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
      Section("Communities") {
        ForEach(subs.filter { $0.user_is_subscriber && $0.uuid != nil }, id: \.uuid) { sub in
          AuroraSidebarCommunityRow(cachedSub: sub)
          .tag(sub.uuid ?? "")
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
