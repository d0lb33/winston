//
//  Search.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import NukeUI
import Defaults

enum SearchScope: String, CaseIterable, Identifiable {
  case all = "All"
  case posts = "Posts"
  case subreddits = "Communities"
  case comments = "Comments"
  case users = "Users"

  var id: String { rawValue }
}

private enum SearchMode {
  case nullState
  case quickCommunities
  case full
}

struct SearchOption: View {
  var activateScope: ()->()
  var active: Bool
  var scope: SearchScope

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    Button {
      withAnimation(.interactiveSpring()) {
        activateScope()
      }
    } label: {
      Text(scope.rawValue)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule(style: .continuous).fill(active ? theme.accent : theme.chipFill))
        .foregroundColor(active ? (theme.isDark ? .black : .white) : .primary)
        .overlay(Capsule(style: .continuous).stroke(active ? theme.accent.opacity(0.45) : theme.hairline, lineWidth: 0.7))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(active ? .isSelected : [])
    .shrinkOnTap()
  }
}

struct SearchLoadMoreFooter: View {
  var loading: Bool

  var body: some View {
    HStack {
      Spacer()
      if loading {
        ProgressView()
          .controlSize(.small)
      } else {
        Color.clear
          .frame(width: 1, height: 1)
      }
      Spacer()
    }
    .frame(minHeight: 36)
  }
}

struct SearchSectionHeader: View {
  let title: LocalizedStringKey
  let count: Int?

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      if let count {
        Text("\(count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .textCase(nil)
  }
}

struct SearchSuggestionRow: View {
  let suggestion: SearchSuggestion
  let select: (SearchSuggestion) -> Void
  let clear: ((String) -> Void)?

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button {
        select(suggestion)
      } label: {
        HStack(alignment: .center, spacing: 16) {
          Image(systemName: suggestion.kind == .recent ? "clock" : "arrow.up.right")
            .font(.headline.weight(.semibold))
            .foregroundStyle(theme.accent)
            .frame(width: 34, height: 34)
            .background(theme.chipFill, in: .circle)

          VStack(alignment: .leading, spacing: 3) {
            Text(suggestion.displayQuery)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)

            if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
              Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if suggestion.kind == .recent, let clear {
        Button(role: .destructive) {
          clear(suggestion.query)
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(theme.chipFill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear recent search")
        .accessibilityValue(suggestion.displayQuery)
      }
    }
    .padding(14)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .stroke(theme.hairline, lineWidth: 0.7)
    )
  }
}

struct SearchRecentSectionHeader: View {
  let clearAll: () -> Void

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: 12) {
      AuroraResultSectionHeader(title: "Recent", count: nil)
      Spacer(minLength: 8)
      Button(role: .destructive) {
        clearAll()
      } label: {
        Label("Clear all", systemImage: "trash")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.accent)
      }
      .buttonStyle(.plain)
    }
    .textCase(nil)
  }
}

@MainActor
private final class SearchViewModel: ObservableObject {
  @Published private(set) var posts: [Post] = []
  @Published private(set) var visiblePosts: [Post] = []
  @Published private(set) var subreddits: [Subreddit] = []
  @Published private(set) var comments: [Comment] = []
  @Published private(set) var users: [User] = []
  @Published private(set) var recentSuggestions: [SearchSuggestion] = []
  @Published private(set) var trendingSuggestions: [SearchSuggestion] = []
  @Published private(set) var loadingInitial = false
  @Published private(set) var loadingMore = false
  @Published private(set) var loadingNullState = false
  @Published private(set) var showEmpty = false
  @Published private(set) var showingNullState = true
  @Published private(set) var showingFullSearch = false

  private var currentQuery = ""
  private var currentScope: SearchScope = .all
  private var currentMode: SearchMode = .nullState
  private var cursors = SearchCursors.empty
  private var requestSerial = 0
  private var searchTask: Task<Void, Never>?
  private var hidingReadPostsUntilUnread = false
  private var hiddenPostIDs: Set<String> = []

  var canLoadMore: Bool {
    switch currentScope {
    case .all:
      return cursors.hasAny
    case .posts:
      return cursors.posts != nil
    case .subreddits:
      return cursors.subreddits != nil
    case .comments:
      return cursors.comments != nil
    case .users:
      return cursors.users != nil
    }
  }

  func refreshQuickCommunities(query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    requestSerial += 1
    let requestID = requestSerial
    searchTask?.cancel()
    currentQuery = trimmed
    currentScope = .subreddits
    currentMode = .quickCommunities

    guard !trimmed.isEmpty else {
      loadNullState()
      return
    }

    updateWithoutAnimation {
      showingNullState = false
      showingFullSearch = false
      loadingInitial = true
      loadingMore = false
      loadingNullState = false
      showEmpty = false
      posts = []
      hiddenPostIDs.removeAll(keepingCapacity: true)
      refreshVisiblePosts()
      subreddits = []
      comments = []
      users = []
      cursors = .empty
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let startedAt = Date()
      let page = await RedditWire.shared.searchCommunityTypeaheadPage(trimmed).mapItems(Subreddit.init(data:))
      guard !Task.isCancelled, self.requestSerial == requestID else { return }

      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.search",
        message: "Search quick communities",
        metadata: [
          "queryLength": "\(trimmed.count)",
          "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
          "subreddits": "\(page.items.count)"
        ]
      )

      self.updateWithoutAnimation {
        self.posts = []
        self.refreshVisiblePosts()
        self.subreddits = page.items.deduped { $0.id }
        self.comments = []
        self.users = []
        self.cursors = .empty
        self.loadingInitial = false
        self.showEmpty = self.subreddits.isEmpty
      }
    }
  }

  func refreshFullSearch(query: String, scope: SearchScope, contentWidth: CGFloat) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    requestSerial += 1
    let requestID = requestSerial
    searchTask?.cancel()
    currentQuery = trimmed
    currentScope = scope
    currentMode = .full

    guard !trimmed.isEmpty else {
      loadNullState()
      return
    }

    updateWithoutAnimation {
      showingNullState = false
      showingFullSearch = true
      loadingInitial = true
      loadingMore = false
      loadingNullState = false
      showEmpty = false
      posts = []
      hiddenPostIDs.removeAll(keepingCapacity: true)
      refreshVisiblePosts()
      subreddits = []
      comments = []
      users = []
      cursors = .empty
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let startedAt = Date()
      let page = await self.fetchPage(query: trimmed, scope: scope, cursors: nil, contentWidth: contentWidth)
      guard !Task.isCancelled, self.requestSerial == requestID else { return }

      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.search",
        message: "Search full results",
        metadata: [
          "scope": scope.rawValue,
          "queryLength": "\(trimmed.count)",
          "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
          "posts": "\(page.posts.items.count)",
          "subreddits": "\(page.subreddits.items.count)",
          "comments": "\(page.comments.items.count)",
          "users": "\(page.users.items.count)"
        ]
      )

      self.updateWithoutAnimation {
        self.apply(page: page, appending: false)
        self.loadingInitial = false
        self.showEmpty = !self.hasVisibleResults
      }
    }
  }

  func loadMore(contentWidth: CGFloat) {
    guard currentMode == .full, !loadingInitial, !loadingMore, canLoadMore, !currentQuery.isEmpty else { return }

    requestSerial += 1
    let requestID = requestSerial
    let query = currentQuery
    let scope = currentScope
    let cursorSnapshot = cursors
    loadingMore = true

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let page = await self.fetchPage(query: query, scope: scope, cursors: cursorSnapshot, contentWidth: contentWidth)
      guard !Task.isCancelled, self.requestSerial == requestID else { return }

      self.updateWithoutAnimation {
        _ = self.apply(page: page, appending: true)
        self.loadingMore = false
        self.showEmpty = !self.hasVisibleResults
      }
    }
  }

  func hideReadPosts(contentWidth: CGFloat) {
    guard currentMode == .full, currentScope == .posts, !loadingInitial, !currentQuery.isEmpty else { return }

    requestSerial += 1
    let requestID = requestSerial
    hidingReadPostsUntilUnread = true
    searchTask?.cancel()

    searchTask = Task { @MainActor [weak self] in
      await self?.continueHidingReadPostsUntilUnread(requestID: requestID, contentWidth: contentWidth)
    }
  }

  func clearSearch() {
    requestSerial += 1
    searchTask?.cancel()
    currentQuery = ""
    currentScope = .all
    currentMode = .nullState
    hidingReadPostsUntilUnread = false
    resetHiddenPosts()
    loadNullState()
  }

  func loadNullState(force: Bool = false) {
    recentSuggestions = Self.localRecentSuggestions()
    guard force || trendingSuggestions.isEmpty else {
      clearState(showNullState: true)
      return
    }

    requestSerial += 1
    let requestID = requestSerial
    searchTask?.cancel()
    currentQuery = ""
    currentScope = .all
    currentMode = .nullState

    updateWithoutAnimation {
      clearState(showNullState: true)
      loadingNullState = true
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let suggestions = await RedditWire.shared.searchTrendingSuggestions()
      guard !Task.isCancelled, self.requestSerial == requestID else { return }
      self.updateWithoutAnimation {
        self.trendingSuggestions = suggestions
        self.loadingNullState = false
      }
    }
  }

  func recordRecentSearch(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    var recent = Defaults[.recentSearchQueries]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
    recent.insert(trimmed, at: 0)
    Defaults[.recentSearchQueries] = Array(recent.prefix(10))
    recentSuggestions = Self.localRecentSuggestions()
  }

  func removeRecentSearch(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    Defaults[.recentSearchQueries] = Defaults[.recentSearchQueries]
      .filter { storedQuery in
        let storedTrimmed = storedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return !storedTrimmed.isEmpty && storedTrimmed.caseInsensitiveCompare(trimmed) != .orderedSame
      }
    recentSuggestions = Self.localRecentSuggestions()
  }

  func clearRecentSearches() {
    Defaults[.recentSearchQueries] = []
    recentSuggestions = []
  }

  func cancel() {
    searchTask?.cancel()
  }

  private var hasVisibleResults: Bool {
    switch currentScope {
    case .all:
      return !visiblePosts.isEmpty || !subreddits.isEmpty || !comments.isEmpty || !users.isEmpty
    case .posts:
      return !visiblePosts.isEmpty
    case .subreddits:
      return !subreddits.isEmpty
    case .comments:
      return !comments.isEmpty
    case .users:
      return !users.isEmpty
    }
  }

  private func clearState(showNullState: Bool = false) {
    updateWithoutAnimation {
      resetHiddenPosts()
      posts = []
      refreshVisiblePosts()
      subreddits = []
      comments = []
      users = []
      cursors = .empty
      loadingInitial = false
      loadingMore = false
      showEmpty = false
      showingNullState = showNullState
      showingFullSearch = false
    }
  }

  private func resetHiddenPosts() {
    guard !hiddenPostIDs.isEmpty || posts.contains(where: { $0.data?.winstonHidden == true }) else { return }
    posts.forEach { $0.data?.winstonHidden = false }
    hiddenPostIDs.removeAll(keepingCapacity: true)
    refreshVisiblePosts()
  }

  @discardableResult
  private func hideVisibleReadPosts() -> Int {
    let readPosts = visiblePosts.filter { $0.data?.winstonSeen == true }
    guard !readPosts.isEmpty else { return 0 }

    withAnimation {
      readPosts.forEach { post in
        post.data?.winstonHidden = true
        hiddenPostIDs.insert(post.id)
      }
      refreshVisiblePosts()
    }

    return readPosts.count
  }

  private func continueHidingReadPostsUntilUnread(requestID: Int, contentWidth: CGFloat) async {
    guard hidingReadPostsUntilUnread, currentMode == .full, currentScope == .posts else { return }

    _ = hideVisibleReadPosts()
    if visiblePosts.contains(where: { !($0.data?.winstonSeen ?? false) }) || !canLoadMore {
      hidingReadPostsUntilUnread = false
      return
    }

    guard !loadingMore, !loadingInitial else { return }

    let query = currentQuery
    let cursorSnapshot = cursors
    loadingMore = true
    let page = await fetchPage(query: query, scope: .posts, cursors: cursorSnapshot, contentWidth: contentWidth)
    guard !Task.isCancelled, requestSerial == requestID else { return }

    let appliedCount = updateWithoutAnimation {
      let count = apply(page: page, appending: true)
      loadingMore = false
      showEmpty = !hasVisibleResults
      return count
    }

    guard appliedCount > 0 else {
      hidingReadPostsUntilUnread = false
      return
    }

    await continueHidingReadPostsUntilUnread(requestID: requestID, contentWidth: contentWidth)
  }

  @discardableResult
  private func updateWithoutAnimation<Result>(_ updates: () -> Result) -> Result {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    return withTransaction(transaction, updates)
  }

  private static func localRecentSuggestions() -> [SearchSuggestion] {
    Defaults[.recentSearchQueries].compactMap { query in
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return SearchSuggestion(kind: .recent, query: trimmed, displayQuery: trimmed, subtitle: nil)
    }
  }

  private func fetchPage(query: String, scope: SearchScope, cursors: SearchCursors?, contentWidth: CGFloat) async -> RedditSearchPageResults {
    switch scope {
    case .all:
      return await RedditWire.shared.searchAllPage(query, cursors: cursors, contentWidth: contentWidth)
    case .posts:
      let page = await RedditWire.shared.searchPostsPage(query, after: cursors?.posts, contentWidth: contentWidth)
      return RedditSearchPageResults(posts: page, subreddits: .empty, comments: .empty, users: .empty)
    case .subreddits:
      let page = await RedditWire.shared.searchSubredditsPage(query, after: cursors?.subreddits).mapItems(Subreddit.init(data:))
      return RedditSearchPageResults(posts: .empty, subreddits: page, comments: .empty, users: .empty)
    case .comments:
      let page = await RedditWire.shared.searchCommentsPage(query, after: cursors?.comments)
      return RedditSearchPageResults(posts: .empty, subreddits: .empty, comments: page, users: .empty)
    case .users:
      let page = await RedditWire.shared.searchUsersPage(query, after: cursors?.users).mapItems(User.init(data:))
      return RedditSearchPageResults(posts: .empty, subreddits: .empty, comments: .empty, users: page)
    }
  }

  @discardableResult
  private func apply(page: RedditSearchPageResults, appending: Bool) -> Int {
    cursors = page.cursors

    if appending {
      let freshPosts = uniquePosts(from: page.posts.items)
      let freshSubreddits = uniqueSubreddits(from: page.subreddits.items)
      let freshComments = uniqueComments(from: page.comments.items)
      let freshUsers = uniqueUsers(from: page.users.items)
      posts.append(contentsOf: freshPosts)
      refreshVisiblePosts()
      subreddits.append(contentsOf: freshSubreddits)
      comments.append(contentsOf: freshComments)
      users.append(contentsOf: freshUsers)
      return freshPosts.count + freshSubreddits.count + freshComments.count + freshUsers.count
    } else {
      posts = page.posts.items.deduped { $0.id }
      hiddenPostIDs.removeAll(keepingCapacity: true)
      refreshVisiblePosts()
      subreddits = page.subreddits.items.deduped { $0.id }
      comments = page.comments.items.deduped { $0.id }
      users = page.users.items.deduped { $0.id }
      return posts.count + subreddits.count + comments.count + users.count
    }
  }

  private func uniquePosts(from newPosts: [Post]) -> [Post] {
    var seen = Set(posts.map(\.id))
    return newPosts.filter { seen.insert($0.id).inserted }
  }

  private func refreshVisiblePosts() {
    visiblePosts = posts.filter { !hiddenPostIDs.contains($0.id) && !($0.data?.winstonHidden ?? false) }
  }

  private func uniqueSubreddits(from newSubreddits: [Subreddit]) -> [Subreddit] {
    var seen = Set(subreddits.map(\.id))
    return newSubreddits.filter { seen.insert($0.id).inserted }
  }

  private func uniqueComments(from newComments: [Comment]) -> [Comment] {
    var seen = Set(comments.map(\.id))
    return newComments.filter { seen.insert($0.id).inserted }
  }

  private func uniqueUsers(from newUsers: [User]) -> [User] {
    var seen = Set(users.map(\.id))
    return newUsers.filter { seen.insert($0.id).inserted }
  }
}

private struct SearchListContent: View {
  @ObservedObject var model: SearchViewModel
  @Binding var searchScope: SearchScope

  let listWidth: CGFloat
  let activateSuggestion: (SearchSuggestion) -> Void
  let selectPost: (Post) -> Void
  let selectComment: (Comment) -> Void
  let selectSubreddit: (Subreddit) -> Void
  let selectUser: (User) -> Void
  let searchAll: () -> Void
  let loadMore: () -> Void

  var body: some View {
    if model.showingNullState {
      SearchNullStateContent(
        recentSuggestions: model.recentSuggestions,
        trendingSuggestions: model.trendingSuggestions,
        loadingNullState: model.loadingNullState,
        activateSuggestion: activateSuggestion,
        removeRecentSearch: model.removeRecentSearch,
        clearRecentSearches: model.clearRecentSearches
      )
    } else if model.showingFullSearch {
      SearchScopePickerSection(searchScope: $searchScope)
      SearchPostsSection(
        posts: model.visiblePosts,
        isVisible: shows(.posts),
        listWidth: listWidth,
        select: selectPost
      )
      SearchCommunitiesSection(subreddits: model.subreddits, isVisible: shows(.subreddits), select: selectSubreddit)
      SearchCommentsSection(comments: model.comments, isVisible: shows(.comments), select: selectComment)
      SearchUsersSection(users: model.users, isVisible: shows(.users), select: selectUser)
      SearchLoadMoreSection(canLoadMore: model.canLoadMore, loading: model.loadingMore, loadMore: loadMore)
    } else {
      SearchAllButtonSection(searchAll: searchAll)
      SearchCommunitiesSection(subreddits: model.subreddits, isVisible: shows(.subreddits), select: selectSubreddit)
    }
  }

  private func shows(_ scope: SearchScope) -> Bool {
    searchScope == .all || searchScope == scope
  }
}

private struct SearchNullStateContent: View {
  let recentSuggestions: [SearchSuggestion]
  let trendingSuggestions: [SearchSuggestion]
  let loadingNullState: Bool
  let activateSuggestion: (SearchSuggestion) -> Void
  let removeRecentSearch: (String) -> Void
  let clearRecentSearches: () -> Void

  var body: some View {
    if !recentSuggestions.isEmpty {
      Section(header: SearchRecentSectionHeader(clearAll: clearRecentSearches)) {
        ForEach(recentSuggestions) { suggestion in
          SearchSuggestionRow(suggestion: suggestion, select: activateSuggestion, clear: removeRecentSearch)
        }
      }
    }

    Section(header: AuroraResultSectionHeader(title: "Trending", count: nil)) {
      if loadingNullState && trendingSuggestions.isEmpty {
        AuroraLoadMoreFooter(loading: true)
      } else {
        ForEach(trendingSuggestions) { suggestion in
          SearchSuggestionRow(suggestion: suggestion, select: activateSuggestion, clear: nil)
        }
      }
    }
  }
}

private struct SearchScopePickerSection: View {
  @Binding var searchScope: SearchScope

  var body: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(SearchScope.allCases) { scope in
            SearchOption(
              activateScope: { searchScope = scope },
              active: searchScope == scope,
              scope: scope
            )
          }
        }
        .padding(.vertical, 2)
      }
    }
  }
}

private struct SearchPostsSection: View {
  let posts: [Post]
  let isVisible: Bool
  let listWidth: CGFloat
  let select: (Post) -> Void

  var body: some View {
    if isVisible && !posts.isEmpty {
      Section(header: AuroraResultSectionHeader(title: "Posts", count: posts.count)) {
        ForEach(posts) { post in
          AuroraPostResultRow(post: post, availableRowWidth: listWidth > 0 ? max(1, listWidth - 28) : nil, select: select)
        }
      }
    }
  }
}

private struct SearchCommunitiesSection: View {
  let subreddits: [Subreddit]
  let isVisible: Bool
  let select: (Subreddit) -> Void

  var body: some View {
    if isVisible && !subreddits.isEmpty {
      Section(header: AuroraResultSectionHeader(title: "Communities", count: subreddits.count)) {
        ForEach(subreddits) { sub in
          AuroraCommunityResultRow(subreddit: sub, select: select)
        }
      }
    }
  }
}

private struct SearchCommentsSection: View {
  let comments: [Comment]
  let isVisible: Bool
  let select: (Comment) -> Void

  var body: some View {
    if isVisible && !comments.isEmpty {
      Section(header: AuroraResultSectionHeader(title: "Comments", count: comments.count)) {
        ForEach(comments) { comment in
          AuroraCommentResultRow(comment: comment, select: select)
        }
      }
    }
  }
}

private struct SearchUsersSection: View {
  let users: [User]
  let isVisible: Bool
  let select: (User) -> Void

  var body: some View {
    if isVisible && !users.isEmpty {
      Section(header: AuroraResultSectionHeader(title: "Users", count: users.count)) {
        ForEach(users) { user in
          AuroraUserResultRow(user: user, select: select)
        }
      }
    }
  }
}

private struct SearchLoadMoreSection: View {
  let canLoadMore: Bool
  let loading: Bool
  let loadMore: () -> Void

  var body: some View {
    if canLoadMore {
      Section {
        AuroraLoadMoreFooter(loading: loading)
          .onAppear(perform: loadMore)
      }
    }
  }
}

private struct SearchAllButtonSection: View {
  let searchAll: () -> Void

  @Environment(\.auroraTheme) private var auroraTheme

  var body: some View {
    Section {
      Button(action: searchAll) {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .font(.headline.weight(.semibold))
            .foregroundStyle(auroraTheme.accent)
            .frame(width: 30, height: 30)
            .background(auroraTheme.chipFill, in: .circle)
          Text("Search all")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(auroraTheme.cardFill, in: RoundedRectangle(cornerRadius: auroraTheme.cornerRadius, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: auroraTheme.cornerRadius, style: .continuous)
            .stroke(auroraTheme.hairline, lineWidth: 0.7)
        )
      }
      .buttonStyle(.plain)
    }
  }
}

struct Search: View {
  @ObservedObject var router: Router
  @State private var searchScope: SearchScope = .all
  @StateObject private var model = SearchViewModel()
  @StateObject private var searchQuery = DebouncedText(delay: 0.25)
  
  @State private var searchViewLoaded: Bool = false
  @State private var listWidth: CGFloat = 0
  @State private var splitNavigation: ColumnNav?
  @State private var isSearchPresented = false
  @State private var suppressEmptyQueryReload = false
  
  @Environment(\.auroraTheme) private var auroraTheme
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.isSearching) private var isSearching
  @EnvironmentObject private var tabInteractions: TabInteractionCenter
  
  var body: some View {
    RedditTwoColumnShell(router: router, tab: .search) { navigation in
      searchRoot
        .onAppear {
          splitNavigation = navigation
        }
    }
//    .swipeAnywhere()
  }

  private var searchRoot: some View {
    TabScrollRoot(
      topID: "search-top",
      tab: .search,
      tabInteractions: tabInteractions,
      request: tabInteractions.requests[.search],
      onResetToRoot: resetSearchHome
    ) {
      SearchListContent(
        model: model,
        searchScope: $searchScope,
        listWidth: listWidth,
        activateSuggestion: activateSuggestion,
        selectPost: selectPost,
        selectComment: selectComment,
        selectSubreddit: selectSubreddit,
        selectUser: selectUser,
        searchAll: searchAll,
        loadMore: { model.loadMore(contentWidth: contentWidth) }
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
    }
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { newWidth in
      let measuredWidth = max(1, newWidth)
      guard abs(measuredWidth - listWidth) > 0.5 else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        listWidth = measuredWidth
      }
    }
    .scrollContentBackground(.hidden)
    .listStyle(.plain)
      .loader(model.loadingInitial, model.showEmpty)
      .scrollDismissesKeyboard(.automatic)
      .searchable(text: $searchQuery.text, isPresented: $isSearchPresented, placement: .toolbar)
      .autocorrectionDisabled(true)
      .textInputAutocapitalization(.none)
      .onChange(of: isSearching) { _, active in
        AppDiagnostics.asyncBreadcrumb(
          "Search focus changed",
          metadata: [
            "active": "\(active)",
            "queryLength": "\(searchQuery.text.count)",
            "showingFullSearch": "\(model.showingFullSearch)",
            "showingNullState": "\(model.showingNullState)"
          ]
        )
      }
      .refreshable {
        if searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          model.loadNullState(force: true)
        } else if model.showingFullSearch {
          model.refreshFullSearch(query: searchQuery.text, scope: searchScope, contentWidth: contentWidth)
        } else {
          model.refreshQuickCommunities(query: searchQuery.text)
        }
      }
      .onSubmit(of: .search) {
        searchScope = .all
        model.recordRecentSearch(searchQuery.text)
        model.refreshFullSearch(query: searchQuery.text, scope: .all, contentWidth: contentWidth)
      }
      .navigationTitle("Search")
      .navigationBarTitleDisplayMode(.inline)
      .tint(auroraTheme.accent)
      .fontDesign(auroraTheme.fontDesign)
      .background { AuroraBackdrop(theme: auroraTheme) }
      .overlay(alignment: .bottomTrailing) {
        if model.showingFullSearch && searchScope == .posts {
          FeedFloatingToolbar {
            model.hideReadPosts(contentWidth: contentWidth)
          }
          .equatable()
          .padding(.trailing, 12)
          .padding(.bottom, 12)
        }
      }
      .onChange(of: searchScope) { _, scope in
        if model.showingFullSearch {
          model.refreshFullSearch(query: searchQuery.debounced, scope: scope, contentWidth: contentWidth)
        }
      }
      .onChange(of: searchQuery.text) { _, val in
        if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          guard !suppressEmptyQueryReload else { return }
          searchScope = .all
          model.loadNullState()
        }
      }
      .onChange(of: searchQuery.debounced) { _, val in
        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
        AppDiagnostics.asyncBreadcrumb(
          "Search debounced query changed",
          metadata: [
            "queryLength": "\(trimmed.count)",
            "showingFullSearch": "\(model.showingFullSearch)"
          ]
        )

        guard !trimmed.isEmpty else {
          if suppressEmptyQueryReload {
            suppressEmptyQueryReload = false
            return
          }
          searchScope = .all
          model.loadNullState()
          return
        }

        if model.showingFullSearch {
          model.refreshFullSearch(query: trimmed, scope: searchScope, contentWidth: contentWidth)
        } else {
          model.refreshQuickCommunities(query: trimmed)
        }
      }
      .onAppear() {
        isSearchPresented = false
        if !searchViewLoaded {
          model.loadNullState()
          searchViewLoaded = true
        }
      }
      .onDisappear {
        model.cancel()
      }
  }

  private func searchAll() {
    dismissSearchField()
    searchScope = .all
    model.recordRecentSearch(searchQuery.text)
    model.refreshFullSearch(query: searchQuery.text, scope: .all, contentWidth: contentWidth)
  }

  private func activateSuggestion(_ suggestion: SearchSuggestion) {
    dismissSearchField()
    searchQuery.text = suggestion.query
    searchScope = .all
    model.recordRecentSearch(suggestion.query)
    model.refreshFullSearch(query: suggestion.query, scope: .all, contentWidth: contentWidth)
  }

  private func selectPost(_ post: Post) {
    dismissSearchField()
    navigateRedditDestination(.reddit(.post(post)), model: splitNavigation, origin: .content)
  }

  private func selectComment(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    dismissSearchField()
    navigateRedditDestination(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)), model: splitNavigation, origin: .content)
  }

  private func selectSubreddit(_ subreddit: Subreddit) {
    dismissSearchField()
    navigateRedditDestination(.reddit(.subFeed(subreddit)), model: splitNavigation, origin: .content)
  }

  private func selectUser(_ user: User) {
    dismissSearchField()
    navigateRedditDestination(.reddit(.user(user)), model: splitNavigation, origin: .content)
  }

  private func dismissSearchField() {
    isSearchPresented = false
  }

  private func resetSearchHome() {
    dismissSearchField()
    searchScope = .all
    if !searchQuery.text.isEmpty {
      suppressEmptyQueryReload = true
      searchQuery.text = ""
    }
    model.loadNullState(force: true)
    tabInteractions.setIsAtTop(.search, true)
  }

}
