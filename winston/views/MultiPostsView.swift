//
//  MultiPostsView.swift
//  winston
//
//  Created by Igor Marcossi on 20/08/23.
//

import SwiftUI
import Defaults

enum MultiViewType: Hashable {
  case posts(Multi)
  case info(Multi)
}

struct MultiPostsView: View {
  @ObservedObject var multi: Multi
  @State private var loading = true
  @StateObject private var posts = NonObservableArray<Post>()
  @State private var lastPostAfter: String?
  @State private var searchText: String = ""
  @State private var sort: SubListingSortOption = Defaults[.SubredditFeedDefSettings].preferredSort
  @State private var newPost = false
  @State private var filter: String = "flair:All"
  @State private var customFilter: FilterData?
  @State private var reachedEndOfFeed: Bool = false
  @State private var feedRequestInFlight: Bool = false
  @State private var hidingReadPostsUntilUnread: Bool = false
  
  @Environment(\.useTheme) private var selectedTheme
  @Environment(\.contentWidth) private var contentWidth
//  @Environment(\.colorScheme) private var cs
  @Default(.SubredditFeedDefSettings) var subredditFeedDefSettings
  @Default(.PostLinkDefSettings) var postLinkDefSettings

  func searchCallback(str: String?) {
    searchText = str ?? ""
    clearAndReloadData()
  }
  
  func filterCallback(str: String) {
    filter = str
  }
  
  func editCustomFilter(filterData: FilterData) {
    customFilter = filterData
  }

  func visiblePosts(_ posts: [Post]) -> [Post] {
    posts.filter { !($0.data?.winstonHidden ?? false) }
  }

  func resetHiddenPosts() {
    let hiddenPosts = posts.data.filter { $0.data?.winstonHidden == true }
    guard !hiddenPosts.isEmpty else { return }

    withAnimation {
      hiddenPosts.forEach { $0.data?.winstonHidden = false }
      posts.data = posts.data
    }
  }

  @discardableResult
  func hideVisibleReadPosts() -> Int {
    let readPosts = visiblePosts(posts.data).filter { $0.data?.winstonSeen == true }
    guard !readPosts.isEmpty else { return 0 }

    withAnimation {
      readPosts.forEach { $0.data?.winstonHidden = true }
      posts.data = posts.data
    }

    return readPosts.count
  }

  func continueHidingReadPostsUntilUnread() {
    guard hidingReadPostsUntilUnread else { return }

    _ = hideVisibleReadPosts()
    let remainingVisiblePosts = visiblePosts(posts.data)

    if remainingVisiblePosts.contains(where: { !($0.data?.winstonSeen ?? false) }) || reachedEndOfFeed || lastPostAfter == nil {
      hidingReadPostsUntilUnread = false
      return
    }

    guard !loading && !feedRequestInFlight else { return }

    fetch(loadMore: true)
  }

  func hideReadPosts() {
    hidingReadPostsUntilUnread = true
    continueHidingReadPostsUntilUnread()
  }
  
  func asyncFetch(force: Bool = false, loadMore: Bool = false) async {
    //    if (multi.data == nil || force) {
    //      await multi.refreshSubreddit()
    //    }
    if posts.data.count > 0 && lastPostAfter == nil && !force {
      return
    }
    if let result = await multi.fetchPosts(sort: sort, after: loadMore ? lastPostAfter : nil, contentWidth: contentWidth), let newPosts = result.0 {
      withAnimation {
        if loadMore {
          posts.data.append(contentsOf: newPosts)
        } else {
          posts.data = newPosts
        }
        loading = false
        lastPostAfter = result.1
        reachedEndOfFeed = newPosts.count == 0
      }
      Task(priority: .background) {
        await RedditWire.shared.updatePostsWithAvatar(posts: newPosts, avatarSize: selectedTheme.postLinks.theme.badge.avatar.size)
      }
    }
  }
  
  func fetch(loadMore: Bool = false, _ searchText: String? = nil, forceRefresh: Bool = false) {
    guard !feedRequestInFlight else { return }

    feedRequestInFlight = true
    loading = true
    Task(priority: .background) {
      await asyncFetch(loadMore: loadMore)
      await MainActor.run {
        feedRequestInFlight = false
        continueHidingReadPostsUntilUnread()
      }
    }
  }
  
  func clearAndReloadData() {
    withAnimation {
      loading = true
      posts.data.removeAll()
      reachedEndOfFeed = false
      hidingReadPostsUntilUnread = false
    }
    
    fetch()
  }
  
  func updatePostsCalcs(_ newTheme: WinstonTheme) {
    Task(priority: .background) { posts.data.forEach { $0.setupWinstonData(data: $0.data, winstonData: $0.winstonData, contentWidth: contentWidth, secondary: false, theme: selectedTheme, sub: $0.winstonData?.subreddit, styleKey: multi.id, fetchAvatar: false) } }
  }
  
  var body: some View {
    GeometryReader { geometry in
      let rowWidth = max(1, geometry.size.width)

      List {
        let filteredPosts = visiblePosts(posts.data)

        ForEach(filteredPosts) { post in
          AuroraPostCardRow(post: post, availableRowWidth: rowWidth) {
            Nav.to(.reddit(.post(post)))
          }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .onAppear {
              if post.id == filteredPosts.last?.id && !loading && !reachedEndOfFeed {
                fetch(loadMore: true)
              }
            }
        }

        if loading {
          HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.vertical, filteredPosts.isEmpty ? 160 : 16)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if reachedEndOfFeed {
          EndOfFeedView()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      }
      //.themedListBG(selectedTheme.postLinks.bg)
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 1)
      .driveInlineVideoCoordinator(coordinateSpace: "auroraFeed")
      //.loader(loading && posts.data.count == 0 && !reachedEndOfFeed)
      .refreshable { await asyncFetch(force: true) }
      .scrollContentBackground(.hidden)
    }
    .navigationBarItems(
      trailing:
        HStack {
          PostSortMenu(selection: $sort)
          
          if let imgLink = multi.data?.icon_url, let imgURL = URL(string: imgLink) {
            Button {
//              routerProxy.router.path.append(SubViewType.info(subreddit))
            } label: {
              URLImage(url: imgURL)
                .scaledToFill()
                .frame(width: 30, height: 30)
                .mask(Circle())
            }
          }
        }
        .animation(nil, value: sort)
    )
    .onAppear {
      resetHiddenPosts()
      if posts.data.count == 0 {
        doThisAfter(0.0) {
          fetch()
        }
      }
    }
    .onChange(of: sort) { _ in clearAndReloadData() }
//    .searchable(text: $searchText, prompt: "Search r/\(subreddit.data?.display_name ?? subreddit.id)")
//    .onChange(of: cs) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: subredditFeedDefSettings.compactPerSubreddit) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: subredditFeedDefSettings.postStylePerSubreddit) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: postLinkDefSettings) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: selectedTheme, perform: updatePostsCalcs)
    .navigationTitle(multi.data?.name ?? "MultiZ")
    //.background(.thinMaterial)
  }
  
}
