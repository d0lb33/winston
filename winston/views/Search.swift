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
  case subreddits = "Subreddits"
  case users = "Users"

  var id: String { rawValue }
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

@MainActor
private final class SearchViewModel: ObservableObject {
  @Published private(set) var posts: [Post] = []
  @Published private(set) var subreddits: [Subreddit] = []
  @Published private(set) var users: [User] = []
  @Published private(set) var loadingInitial = false
  @Published private(set) var loadingMore = false
  @Published private(set) var showEmpty = false

  private var currentQuery = ""
  private var currentScope: SearchScope = .all
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
    case .users:
      return cursors.users != nil
    }
  }

  func refresh(query: String, scope: SearchScope, contentWidth: CGFloat) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    requestSerial += 1
    let requestID = requestSerial
    searchTask?.cancel()
    currentQuery = trimmed
    currentScope = scope

    guard !trimmed.isEmpty else {
      clearState()
      return
    }

    withAnimation {
      loadingInitial = true
      loadingMore = false
      showEmpty = false
      posts = []
      subreddits = []
      users = []
      cursors = .empty
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let page = await self.fetchPage(query: trimmed, scope: scope, cursors: nil, contentWidth: contentWidth)
      guard !Task.isCancelled, self.requestSerial == requestID else { return }

      withAnimation {
        self.apply(page: page, appending: false)
        self.loadingInitial = false
        self.showEmpty = !self.hasVisibleResults
      }
    }
  }

  func loadMore(contentWidth: CGFloat) {
    guard !loadingInitial, !loadingMore, canLoadMore, !currentQuery.isEmpty else { return }

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
    clearState()
  }

  func cancel() {
    searchTask?.cancel()
  }

  private var hasVisibleResults: Bool {
    switch currentScope {
    case .all:
      return !posts.isEmpty || !subreddits.isEmpty || !users.isEmpty
    case .posts:
      return !posts.isEmpty
    case .subreddits:
      return !subreddits.isEmpty
    case .users:
      return !users.isEmpty
    }
  }

  private func clearState() {
    withAnimation {
      posts = []
      subreddits = []
      users = []
      cursors = .empty
      loadingInitial = false
      loadingMore = false
      showEmpty = false
    }
  }

  private func fetchPage(query: String, scope: SearchScope, cursors: SearchCursors?, contentWidth: CGFloat) async -> RedditSearchPageResults {
    switch scope {
    case .all:
      return await RedditWire.shared.searchAllPage(query, cursors: cursors, contentWidth: contentWidth)
    case .posts:
      let page = await RedditWire.shared.searchPostsPage(query, after: cursors?.posts, contentWidth: contentWidth)
      return RedditSearchPageResults(posts: page, subreddits: .empty, users: .empty)
    case .subreddits:
      let page = await RedditWire.shared.searchSubredditsPage(query, after: cursors?.subreddits).mapItems(Subreddit.init(data:))
      return RedditSearchPageResults(posts: .empty, subreddits: page, users: .empty)
    case .users:
      let page = await RedditWire.shared.searchUsersPage(query, after: cursors?.users).mapItems(User.init(data:))
      return RedditSearchPageResults(posts: .empty, subreddits: .empty, users: page)
    }
  }

  private func apply(page: RedditSearchPageResults, appending: Bool) {
    cursors = page.cursors

    if appending {
      posts.append(contentsOf: uniquePosts(from: page.posts.items))
      subreddits.append(contentsOf: uniqueSubreddits(from: page.subreddits.items))
      users.append(contentsOf: uniqueUsers(from: page.users.items))
    } else {
      posts = page.posts.items.deduped { $0.id }
      subreddits = page.subreddits.items.deduped { $0.id }
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

  private func uniqueUsers(from newUsers: [User]) -> [User] {
    var seen = Set(users.map(\.id))
    return newUsers.filter { seen.insert($0.id).inserted }
  }
}

struct Search: View {
  @ObservedObject var router: Router
  @State private var searchScope: SearchScope = .all
  @StateObject private var model = SearchViewModel()
  @StateObject private var searchQuery = DebouncedText(delay: 0.35)
  
  @State private var dummyAllSub: Subreddit? = nil
  @State private var searchViewLoaded: Bool = false
  
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Environment(\.useTheme) private var theme
  @Environment(\.contentWidth) private var contentWidth
  
  var body: some View {
    NavigationStack(path: $router.fullPath) {
      List {
        Group {
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
            Section(header: searchHeader("Posts", count: model.posts.count)) {
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
            Section(header: searchHeader("Subreddits", count: model.subreddits.count)) {
              ForEach(model.subreddits) { sub in
                SubredditLink(sub: sub)
              }
            }
          }

          if shows(.users) && !model.users.isEmpty {
            Section(header: searchHeader("Users", count: model.users.count)) {
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
        model.refresh(query: searchQuery.text, scope: searchScope, contentWidth: contentWidth)
      }
      .onSubmit(of: .search) {
        model.refresh(query: searchQuery.text, scope: searchScope, contentWidth: contentWidth)
      }
      .navigationTitle("Search")
      .onChange(of: searchScope) { scope in
        model.refresh(query: searchQuery.debounced, scope: scope, contentWidth: contentWidth)
      }
      .onChange(of: searchQuery.text) { val in
        if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          model.clearSearch()
        }
      }
      .onChange(of: searchQuery.debounced) { val in
        model.refresh(query: val, scope: searchScope, contentWidth: contentWidth)
      }
      .onAppear() {
        if !searchViewLoaded {
          dummyAllSub = Subreddit(id: "all")
          searchViewLoaded = true
        }
      }
      .onDisappear {
        model.cancel()
      }
    }
//    .swipeAnywhere()
  }

  private func searchHeader(_ title: String, count: Int) -> some View {
    HStack(spacing: 8) {
      Text(title)
      Text("\(count)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .textCase(nil)
  }

  private func shows(_ scope: SearchScope) -> Bool {
    searchScope == .all || searchScope == scope
  }
}
