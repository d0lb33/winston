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

private struct SearchResultsPayload {
  let posts: [Post]
  let subs: [Subreddit]
  let users: [User]
}

private extension SearchScope {
  func results(query: String, contentWidth: CGFloat) async -> SearchResultsPayload {
    switch self {
    case .all:
      let result = await RedditWire.shared.searchAll(query, contentWidth: contentWidth)
      return SearchResultsPayload(posts: result.posts, subs: result.subreddits, users: result.users)
    case .posts:
      let posts = await RedditWire.shared.searchPosts(query, contentWidth: contentWidth)
      return SearchResultsPayload(posts: posts, subs: [], users: [])
    case .subreddits:
      let subs = await RedditWire.shared.searchSubreddits(query).map(Subreddit.init(data:))
      return SearchResultsPayload(posts: [], subs: subs, users: [])
    case .users:
      let users = await RedditWire.shared.searchUsers(query).map(User.init(data:))
      return SearchResultsPayload(posts: [], subs: [], users: users)
    }
  }
}

struct Search: View {
  @ObservedObject var router: Router
  @State private var searchScope: SearchScope = .all
  @StateObject private var resultsSubs = ObservableArray<Subreddit>()
  @StateObject private var resultsUsers = ObservableArray<User>()
  @StateObject private var resultPosts = ObservableArray<Post>()
  @State private var loading = false
  @State private var hideSpinner = false
  @StateObject var searchQuery = DebouncedText(delay: 0.25)
  
  @State private var dummyAllSub: Subreddit? = nil
  @State private var searchViewLoaded: Bool = false
  
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Environment(\.useTheme) private var theme
  @Environment(\.contentWidth) private var contentWidth
  
  func fetch() {
    let query = searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if query == "" { return }
    let scope = searchScope
    withAnimation {
      loading = true
      hideSpinner = false
    }

    resultsSubs.data.removeAll()
    resultsUsers.data.removeAll()
    resultPosts.data.removeAll()

    Task(priority: .background) {
      let searchResults = await scope.results(query: query, contentWidth: contentWidth)

      await MainActor.run {
        withAnimation {
          resultPosts.data = searchResults.posts
          resultsSubs.data = searchResults.subs
          resultsUsers.data = searchResults.users
          loading = false
          hideSpinner = searchResults.posts.isEmpty && searchResults.subs.isEmpty && searchResults.users.isEmpty
        }
      }
    }
  }
  
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

          if shows(.posts) && !resultPosts.data.isEmpty {
            Section(header: searchHeader("Posts", count: resultPosts.data.count)) {
              if let dummyAllSub = dummyAllSub {
                ForEach(resultPosts.data) { post in
                  if let winstonData = post.winstonData {
                    PostLink(id: post.id, theme: theme.postLinks, showSub: true, compactPerSubreddit: nil, contentWidth: contentWidth, defSettings: postLinkDefSettings)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .animation(.default, value: resultPosts.data)
                    .environmentObject(post)
                    .environmentObject(dummyAllSub)
                    .environmentObject(winstonData)
                  }
                }
              }
            }
          }

          if shows(.subreddits) && !resultsSubs.data.isEmpty {
            Section(header: searchHeader("Subreddits", count: resultsSubs.data.count)) {
              ForEach(resultsSubs.data) { sub in
                SubredditLink(sub: sub)
              }
            }
          }

          if shows(.users) && !resultsUsers.data.isEmpty {
            Section(header: searchHeader("Users", count: resultsUsers.data.count)) {
              ForEach(resultsUsers.data) { user in
                UserLink(user: user)
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
      .loader(loading, hideSpinner && !searchQuery.text.isEmpty)
      .injectInTabDestinations(viewControllerHolder: router.navController)
      .scrollDismissesKeyboard(.automatic)
      .searchable(text: $searchQuery.text, placement: .toolbar)
      .autocorrectionDisabled(true)
      .textInputAutocapitalization(.none)
      .refreshable { fetch() }
      .onSubmit(of: .search) { fetch() }
      .navigationTitle("Search")
      .onChange(of: searchScope) { _ in fetch() }
      .onChange(of: searchQuery.debounced) { val in
        if val == "" {
          resultsSubs.data = []
          resultsUsers.data = []
          resultPosts.data = []
        }
        fetch()
      }
      .onAppear() {
        if !searchViewLoaded {
          dummyAllSub = Subreddit(id: "all")
          searchViewLoaded = true
        }
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
