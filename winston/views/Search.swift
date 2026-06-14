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
  var body: some View {
    Button {
      withAnimation(.interactiveSpring()) {
        activateScope()
      }
    } label: {
      Text(scope.rawValue)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule(style: .continuous).fill(active ? Color.accentColor : .secondary.opacity(0.15)))
        .foregroundColor(active ? .white : .primary)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke((active ? Color.white : .primary).opacity(0.01), lineWidth: 1))
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
  let select: (String) -> Void

  var body: some View {
    Button {
      select(suggestion.query)
    } label: {
      HStack(alignment: .center, spacing: 16) {
        Image(systemName: suggestion.kind == .recent ? "clock" : "arrow.up.right")
          .font(.title3.weight(.semibold))
          .foregroundColor(.primary)
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text(suggestion.displayQuery)
            .font(.body)
            .foregroundColor(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)

          if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.subheadline)
              .foregroundColor(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

@MainActor
private final class SearchViewModel: ObservableObject {
  @Published private(set) var posts: [Post] = []
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

    withAnimation {
      showingNullState = false
      showingFullSearch = false
      loadingInitial = true
      loadingMore = false
      loadingNullState = false
      showEmpty = false
      posts = []
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

      withAnimation {
        self.posts = []
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

    withAnimation {
      showingNullState = false
      showingFullSearch = true
      loadingInitial = true
      loadingMore = false
      loadingNullState = false
      showEmpty = false
      posts = []
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

      withAnimation {
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

      withAnimation {
        self.apply(page: page, appending: true)
        self.loadingMore = false
        self.showEmpty = !self.hasVisibleResults
      }
    }
  }

  func clearSearch() {
    requestSerial += 1
    searchTask?.cancel()
    currentQuery = ""
    currentScope = .all
    currentMode = .nullState
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

    withAnimation {
      clearState(showNullState: true)
      loadingNullState = true
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let suggestions = await RedditWire.shared.searchTrendingSuggestions()
      guard !Task.isCancelled, self.requestSerial == requestID else { return }
      withAnimation {
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

  func cancel() {
    searchTask?.cancel()
  }

  private var hasVisibleResults: Bool {
    switch currentScope {
    case .all:
      return !posts.isEmpty || !subreddits.isEmpty || !comments.isEmpty || !users.isEmpty
    case .posts:
      return !posts.isEmpty
    case .subreddits:
      return !subreddits.isEmpty
    case .comments:
      return !comments.isEmpty
    case .users:
      return !users.isEmpty
    }
  }

  private func clearState(showNullState: Bool = false) {
    withAnimation {
      posts = []
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

  private func apply(page: RedditSearchPageResults, appending: Bool) {
    cursors = page.cursors

    if appending {
      posts.append(contentsOf: uniquePosts(from: page.posts.items))
      subreddits.append(contentsOf: uniqueSubreddits(from: page.subreddits.items))
      comments.append(contentsOf: uniqueComments(from: page.comments.items))
      users.append(contentsOf: uniqueUsers(from: page.users.items))
    } else {
      posts = page.posts.items.deduped { $0.id }
      subreddits = page.subreddits.items.deduped { $0.id }
      comments = page.comments.items.deduped { $0.id }
      users = page.users.items.deduped { $0.id }
    }
  }

  private func uniquePosts(from newPosts: [Post]) -> [Post] {
    var seen = Set(posts.map(\.id))
    return newPosts.filter { seen.insert($0.id).inserted }
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

struct Search: View {
  @ObservedObject var router: Router
  @State private var searchScope: SearchScope = .all
  @StateObject private var model = SearchViewModel()
  @StateObject private var searchQuery = DebouncedText(delay: 0.25)
  
  @State private var dummyAllSub: Subreddit? = nil
  @State private var searchViewLoaded: Bool = false
  
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Environment(\.useTheme) private var theme
  @Environment(\.contentWidth) private var contentWidth
  
  var body: some View {
    NavigationStack(path: $router.fullPath) {
      List {
        Group {
          if model.showingNullState {
            if !model.recentSuggestions.isEmpty {
              Section(header: SearchSectionHeader(title: "Recent", count: nil)) {
                ForEach(model.recentSuggestions) { suggestion in
                  SearchSuggestionRow(suggestion: suggestion, select: activateSuggestion)
                }
              }
            }

            Section(header: SearchSectionHeader(title: "Trending", count: nil)) {
              if model.loadingNullState && model.trendingSuggestions.isEmpty {
                SearchLoadMoreFooter(loading: true)
              } else {
                ForEach(model.trendingSuggestions) { suggestion in
                  SearchSuggestionRow(suggestion: suggestion, select: activateSuggestion)
                }
              }
            }
          } else if model.showingFullSearch {
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

            if shows(.posts) && !model.posts.isEmpty {
              Section(header: SearchSectionHeader(title: "Posts", count: model.posts.count)) {
                if let dummyAllSub = dummyAllSub {
                  ForEach(model.posts) { post in
                    if let winstonData = post.winstonData {
                      PostLink(id: post.id, theme: theme.postLinks, showSub: true, compactPerSubreddit: nil, contentWidth: contentWidth, defSettings: postLinkDefSettings)
                      .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                      .animation(.default, value: model.posts)
                      .environmentObject(post)
                      .environmentObject(dummyAllSub)
                      .environmentObject(winstonData)
                    }
                  }
                }
              }
            }

            if shows(.subreddits) && !model.subreddits.isEmpty {
              Section(header: SearchSectionHeader(title: "Communities", count: model.subreddits.count)) {
                ForEach(model.subreddits) { sub in
                  SubredditLink(sub: sub)
                }
              }
            }

            if shows(.comments) && !model.comments.isEmpty {
              Section(header: SearchSectionHeader(title: "Comments", count: model.comments.count)) {
                ForEach(model.comments) { comment in
                  if let winstonData = comment.winstonData {
                    CommentLink(showReplies: false, comment: comment, commentWinstonData: winstonData, children: comment.childrenWinston)
                  }
                }
              }
            }

            if shows(.users) && !model.users.isEmpty {
              Section(header: SearchSectionHeader(title: "Users", count: model.users.count)) {
                ForEach(model.users) { user in
                  UserLink(user: user)
                }
              }
            }

            if model.canLoadMore {
              Section {
                SearchLoadMoreFooter(loading: model.loadingMore)
                  .onAppear {
                    model.loadMore(contentWidth: contentWidth)
                  }
              }
            }
          } else {
            Section {
              Button {
                searchScope = .all
                model.recordRecentSearch(searchQuery.text)
                model.refreshFullSearch(query: searchQuery.text, scope: .all, contentWidth: contentWidth)
              } label: {
                Label("Search all", systemImage: "magnifyingglass")
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
            }

            if !model.subreddits.isEmpty {
              Section(header: SearchSectionHeader(title: "Communities", count: model.subreddits.count)) {
                ForEach(model.subreddits) { sub in
                  SubredditLink(sub: sub)
                }
              }
            }
          }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
      }
      .themedListBG(theme.lists.bg)
      .listStyle(.plain)
      .loader(model.loadingInitial, model.showEmpty)
      .injectInTabDestinations(viewControllerHolder: router.navController)
      .scrollDismissesKeyboard(.automatic)
      .searchable(text: $searchQuery.text, placement: .toolbar)
      .autocorrectionDisabled(true)
      .textInputAutocapitalization(.none)
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
      .onChange(of: searchScope) { scope in
        if model.showingFullSearch {
          model.refreshFullSearch(query: searchQuery.debounced, scope: scope, contentWidth: contentWidth)
        }
      }
      .onChange(of: searchQuery.text) { val in
        if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          searchScope = .all
          model.loadNullState()
        }
      }
      .onChange(of: searchQuery.debounced) { val in
        if model.showingFullSearch {
          model.refreshFullSearch(query: val, scope: searchScope, contentWidth: contentWidth)
        } else {
          model.refreshQuickCommunities(query: val)
        }
      }
      .onAppear() {
        if !searchViewLoaded {
          dummyAllSub = Subreddit(id: "all")
          model.loadNullState()
          searchViewLoaded = true
        }
      }
      .onDisappear {
        model.cancel()
      }
    }
//    .swipeAnywhere()
  }

  private func activateSuggestion(_ query: String) {
    searchQuery.text = query
    model.recordRecentSearch(query)
    model.refreshQuickCommunities(query: query)
  }

  private func shows(_ scope: SearchScope) -> Bool {
    searchScope == .all || searchScope == scope
  }
}
