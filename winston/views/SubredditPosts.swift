//
//  SubredditPosts.swift
//  winston
//
//  Created by Igor Marcossi on 26/06/23.
//

import SwiftUI
import Defaults
import SwiftUIIntrospect
import CoreData

enum SubViewType: Hashable {
  case posts(Subreddit)
  case info(Subreddit)
}

private enum SavedFeedTab: String, CaseIterable, Identifiable {
  case posts = "Posts"
  case comments = "Comments"

  var id: String { rawValue }
}

struct SubredditPosts: View, Equatable {
  static func == (lhs: SubredditPosts, rhs: SubredditPosts) -> Bool {
    lhs.subreddit == rhs.subreddit
  }
  
  @ObservedObject var subreddit: Subreddit
  @Default(.filteredSubreddits) private var filteredSubreddits
  @State private var loading = true
  @StateObject private var posts = NonObservableArray<Post>()
  @State private var loadedPosts: Set<String> = []
  @State private var lastPostAfter: String?
  @State private var searchText: String = ""
  @State private var sort: SubListingSortOption
  @State private var newPost = false
  @State private var filters: [FilterData] = []
  @State private var filter = "flair:All"
  @State private var customFilter: FilterData?
  
  @State private var savedPosts: [Post]?
  @State private var savedComments: [Comment]?
  @State private var savedPostsAfter: String?
  @State private var savedCommentsAfter: String?
  @State private var loadedSavedPostIDs: Set<String> = []
  @State private var loadedSavedCommentIDs: Set<String> = []
  @State private var savedPostsReachedEnd: Bool = false
  @State private var savedCommentsReachedEnd: Bool = false
  @State private var selectedSavedFeed: SavedFeedTab = .posts
  @State private var loadNextSavedData: Bool = false
  @State private var loadingSavedPosts = false
  @State private var loadingSavedComments = false
  @State private var isSavedSubreddit: Bool = false
  @State private var hasViewLoaded: Bool = false
  @State private var reachedEndOfFeed: Bool = false
  @State private var showLoadMoreButton: Bool = false
  @State private var feedRequestInFlight: Bool = false
  @State private var hidingReadPostsUntilUnread: Bool = false
  
  @StateObject private var unfilteredPosts = NonObservableArray<Post>()
  @State private var unfilteredLastPostAfter: String?
  @State private var unfilteredreachedEndOfFeed: Bool = false
  
  @Environment(\.useTheme) private var selectedTheme
//  @Environment(\.colorScheme) private var cs
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.horizontalSizeClass) private var hSizeClass
	
  @Default(.SubredditFeedDefSettings) var subredditFeedDefSettings
  @Default(.PostLinkDefSettings) var postLinkDefSettings
  @Default(.PostPageDefSettings) private var postPageDefSettings

  let context = PersistenceController.shared.container.newBackgroundContext()
  
  init(subreddit: Subreddit) {
    self.subreddit = subreddit
    let defSettings = Defaults[.SubredditFeedDefSettings]
    _sort = State(initialValue: defSettings.perSubredditSort ? (defSettings.subredditSorts[subreddit.id] ?? defSettings.preferredSort) : defSettings.preferredSort)
  }
  
  var isFeedsAndSuch: Bool { feedsAndSuch.contains(subreddit.id) }
  
  func getFilteredPosts(posts: [Post], onlyUnseen: Bool = false) -> [Post] {
    let filtered = posts.filter { !($0.data?.winstonHidden ?? false) }
    
    let filterData = FilterData.getTypeAndText(filter)
    
    if filterData[0] == "flair" {
      if filterData[1] == "All" { return filtered }
      return filtered.filter({ flairWithoutEmojis(str: $0.data?.link_flair_text)?.first ?? "" == filterData[1] })
    } else if filterData[0] == "filter" {
      return filtered.filter({ ($0.data?.title.lowercased().contains(filterData[1].lowercased()) ?? false) ||
                               ($0.data?.selftext.lowercased().contains(filterData[1].lowercased()) ?? false) })
    }
    
    return filtered
  }
  
  func searchCallback(str: String?) {
    withAnimation {
      searchText = str ?? ""
    }
    
    clearAndLoadData(withSearchText: str)
  }
  
  func filterCallback(str: String) {
    withAnimation {
      filter = str
    }
    
    // No posts left to appear, so load more posts
    if filter == "flair:All" && lastPostAfter != nil && getFilteredPosts(posts: posts.data, onlyUnseen: true).count == 0 {
      if searchText.isEmpty {
        fetch(true, nil)
      } else {
        fetch(true, searchText)
      }
    }
  }
  
  func editCustomFilter(filterData: FilterData) {
    customFilter = filterData
  }

  func resetHiddenPosts() {
    let hiddenPosts = posts.data.filter { $0.data?.winstonHidden == true }
    guard !hiddenPosts.isEmpty else { return }

    withAnimation {
      hiddenPosts.forEach { $0.data?.winstonHidden = false }
      posts.data = posts.data
      unfilteredPosts.data = unfilteredPosts.data
    }
  }

  @discardableResult
  func hideVisibleReadPosts() -> Int {
    let visibleReadPosts = getFilteredPosts(posts: posts.data).filter { $0.data?.winstonSeen == true }
    guard !visibleReadPosts.isEmpty else { return 0 }

    withAnimation {
      visibleReadPosts.forEach { $0.data?.winstonHidden = true }
      posts.data = posts.data
      unfilteredPosts.data = unfilteredPosts.data
    }

    return visibleReadPosts.count
  }

  func continueHidingReadPostsUntilUnread() {
    guard hidingReadPostsUntilUnread else { return }

    let hiddenCount = hideVisibleReadPosts()
    let visiblePosts = getFilteredPosts(posts: posts.data)

    if visiblePosts.contains(where: { !($0.data?.winstonSeen ?? false) }) || reachedEndOfFeed || lastPostAfter == nil {
      hidingReadPostsUntilUnread = false
      return
    }

    guard !loading && !feedRequestInFlight else { return }

    AppDiagnostics.asyncBreadcrumb(
      "Hide-read paging requested",
      metadata: [
        "subreddit": subreddit.id,
        "hidden": "\(hiddenCount)",
        "loadedPosts": "\(posts.data.count)",
        "after": lastPostAfter ?? "nil",
        "search": searchText
      ]
    )

    if searchText.isEmpty {
      fetch(true, nil, forceRefresh: true)
    } else {
      fetch(true, searchText, forceRefresh: true)
    }
  }

  func hideReadPosts() {
    hidingReadPostsUntilUnread = true
    continueHidingReadPostsUntilUnread()
  }
  
  func asyncFetch(force: Bool = false, loadMore: Bool = false, searchText: String? = nil, forceRefresh: Bool = false) async throws {
    if (subreddit.data == nil || force) && !isFeedsAndSuch {
      await subreddit.refreshSubreddit()
    }
    
    if (searchText == nil || searchText!.isEmpty) && !loadMore && !forceRefresh && !unfilteredPosts.data.isEmpty {
      AppDiagnostics.asyncBreadcrumb(
        "Feed restored from in-memory cache",
        metadata: [
          "subreddit": subreddit.id,
          "cachedPosts": "\(unfilteredPosts.data.count)",
          "after": unfilteredLastPostAfter ?? "nil",
          "reachedEnd": "\(unfilteredreachedEndOfFeed)"
        ]
      )
      posts.data = unfilteredPosts.data
      resetHiddenPosts()
      lastPostAfter = unfilteredLastPostAfter
      reachedEndOfFeed = unfilteredreachedEndOfFeed
      return
    }
    
    if posts.data.count > 0 && lastPostAfter == nil && !force {
      AppDiagnostics.asyncRecord(
        .info,
        category: "ui.feed",
        message: "Feed load skipped because cursor is nil",
        metadata: [
          "subreddit": subreddit.id,
          "posts": "\(posts.data.count)",
          "loadMore": "\(loadMore)",
          "search": searchText ?? ""
        ]
      )
      reachedEndOfFeed = true
      return
    }
  
    if !loadMore && !subreddit.id.starts(with: "t5") {
      // Remove filters from home/all/popular so it only shows filters for current posts
      Task(priority: .userInitiated) {
        subreddit.resetFlairs()
      }
    }
    
    withAnimation {
      loading = true
    }
    
    if subreddit.id != "saved" {
      AppDiagnostics.asyncBreadcrumb(
        "Feed fetch started",
        metadata: [
          "subreddit": subreddit.id,
          "sort": sort.rawVal.value,
          "loadMore": "\(loadMore)",
          "existingPosts": "\(posts.data.count)",
          "after": (loadMore ? lastPostAfter : nil) ?? "nil",
          "search": searchText ?? ""
        ]
      )
      if let result = await subreddit.fetchPosts(sort: sort, after: loadMore ? lastPostAfter : nil, searchText: searchText, contentWidth: contentWidth), let newPosts = result.0 {
        Task(priority: .background) { await RedditWire.shared.updatePostsWithAvatar(posts: newPosts, avatarSize: selectedTheme.postLinks.theme.badge.avatar.size) }
        withAnimation {
          let duplicateCount = newPosts.filter { loadedPosts.contains($0.id) }.count
          let filteredCount = newPosts.filter { !loadedPosts.contains($0.id) && filteredSubreddits.contains($0.data?.subreddit ?? "") }.count
          let newPostsFiltered = newPosts.filter { !loadedPosts.contains($0.id) && !filteredSubreddits.contains($0.data?.subreddit ?? "") }
          AppDiagnostics.asyncRecord(
            newPosts.isEmpty || (!loadMore && newPostsFiltered.isEmpty) ? .warning : .info,
            category: "ui.feed",
            message: "Feed fetch applied",
            metadata: [
              "subreddit": subreddit.id,
              "loadMore": "\(loadMore)",
              "received": "\(newPosts.count)",
              "applied": "\(newPostsFiltered.count)",
              "duplicates": "\(duplicateCount)",
              "filtered": "\(filteredCount)",
              "existingBefore": "\(posts.data.count)",
              "nextAfter": result.1 ?? "nil"
            ]
          )
          
          if loadMore {
            posts.data.append(contentsOf: newPostsFiltered)
//            posts.data.append(contentsOf: newPosts)
          } else {
            posts.data = newPostsFiltered
//            posts.data = newPosts
          }
          
          newPostsFiltered.forEach { loadedPosts.insert($0.id) }
          
          loading = false
          lastPostAfter = result.1
          reachedEndOfFeed = result.1 == nil
          
//        reachedEndOfFeed = newPostsFiltered.count == 0
          
          Task(priority: .background) {
            self.subreddit.loadFlairs( { loaded in
              DispatchQueue.main.async {
                withAnimation {
                  filters = loaded
                }
              }
            })
          }
                    
          // Save posts if no searchText
          if searchText == nil || searchText!.isEmpty {
            unfilteredPosts.data = posts.data
            unfilteredLastPostAfter = lastPostAfter
            unfilteredreachedEndOfFeed = reachedEndOfFeed
          }
          
          subreddit.loadFlairs() { loaded in
            DispatchQueue.main.async {
              filters = loaded
            }
          }
        }
      } else {
        AppDiagnostics.asyncRecord(
          .error,
          category: "ui.feed",
          message: "Feed fetch returned no result",
          metadata: [
            "subreddit": subreddit.id,
            "loadMore": "\(loadMore)",
            "after": (loadMore ? lastPostAfter : nil) ?? "nil",
            "search": searchText ?? ""
          ]
        )
        loading = false
      }
    } else {
      await asyncFetchSaved(loadMore: loadMore)
    }
  }

  func asyncFetchSaved(loadMore: Bool = false) async {
    switch selectedSavedFeed {
    case .posts:
      guard !loadingSavedPosts else { return }
      if loadMore && savedPostsReachedEnd {
        loading = false
        reachedEndOfFeed = true
        return
      }

      loadingSavedPosts = true
      defer { loadingSavedPosts = false }

      if let result = await subreddit.fetchSavedPosts(after: loadMore ? savedPostsAfter : nil, contentWidth: contentWidth), let newPosts = result.0 {
        if !loadMore {
          loadedSavedPostIDs.removeAll()
        }
        let uniquePosts = newPosts.filter { loadedSavedPostIDs.insert($0.id).inserted }
        Task(priority: .background) { await RedditWire.shared.updatePostsWithAvatar(posts: uniquePosts, avatarSize: selectedTheme.postLinks.theme.badge.avatar.size) }
        withAnimation {
          if loadMore {
            savedPosts = (savedPosts ?? []) + uniquePosts
          } else {
            savedPosts = uniquePosts
          }

          loading = false
          savedPostsAfter = result.1
          savedPostsReachedEnd = result.1 == nil
          reachedEndOfFeed = savedPostsReachedEnd
        }
      } else {
        loading = false
        savedPostsReachedEnd = true
        reachedEndOfFeed = true
      }
    case .comments:
      guard !loadingSavedComments else { return }
      if loadMore && savedCommentsReachedEnd {
        loading = false
        reachedEndOfFeed = true
        return
      }

      loadingSavedComments = true
      defer { loadingSavedComments = false }

      if let result = await subreddit.fetchSavedComments(after: loadMore ? savedCommentsAfter : nil), let newComments = result.0 {
        if !loadMore {
          loadedSavedCommentIDs.removeAll()
        }
        let uniqueComments = newComments.filter { loadedSavedCommentIDs.insert($0.id).inserted }
        withAnimation {
          if loadMore {
            savedComments = (savedComments ?? []) + uniqueComments
          } else {
            savedComments = uniqueComments
          }

          loading = false
          savedCommentsAfter = result.1
          savedCommentsReachedEnd = result.1 == nil
          reachedEndOfFeed = savedCommentsReachedEnd
        }
      } else {
        loading = false
        savedCommentsReachedEnd = true
        reachedEndOfFeed = true
      }
    }
  }
  
  func fetch(_ loadMore: Bool = false, _ searchText: String? = nil, forceRefresh: Bool = false) {
    guard !feedRequestInFlight else {
      AppDiagnostics.asyncBreadcrumb(
        "Feed fetch suppressed while request is in flight",
        metadata: [
          "subreddit": subreddit.id,
          "loadMore": "\(loadMore)",
          "after": (loadMore ? lastPostAfter : nil) ?? "nil",
          "search": searchText ?? ""
        ]
      )
      return
    }

    feedRequestInFlight = true
    loading = true
    Task(priority: .background) {
      do {
        try await asyncFetch(loadMore: loadMore, searchText: searchText, forceRefresh: forceRefresh)
      } catch {
        print(error)
      }
      await MainActor.run {
        feedRequestInFlight = false
        continueHidingReadPostsUntilUnread()
      }
    }
  }
  
  func clearAndLoadData(withSearchText searchText: String? = nil, forceRefresh: Bool = false) {
    withAnimation {
//      posts.data.removeAll()
      loadedPosts.removeAll()
      reachedEndOfFeed = false
      hidingReadPostsUntilUnread = false
      
      if isSavedSubreddit {
        switch selectedSavedFeed {
        case .posts:
          savedPosts?.removeAll()
          savedPostsAfter = nil
          loadedSavedPostIDs.removeAll()
          savedPostsReachedEnd = false
        case .comments:
          savedComments?.removeAll()
          savedCommentsAfter = nil
          loadedSavedCommentIDs.removeAll()
          savedCommentsReachedEnd = false
        }
      }
    }
    
    if let searchText = searchText, !searchText.isEmpty {
      fetch(false, searchText, forceRefresh: forceRefresh)
    } else {
      fetch(forceRefresh: forceRefresh)
    }
  }
  
  func updatePostsCalcs(_ newTheme: WinstonTheme) {
    Task(priority: .background) { posts.data.forEach { $0.setupWinstonData(data: $0.data, winstonData: $0.winstonData, contentWidth: contentWidth, secondary: false, theme: selectedTheme, sub: subreddit, styleKey: subreddit.id, fetchAvatar: false) } }
  }

  private var savedMixedMediaLinks: [Either<Post, Comment>]? {
    switch selectedSavedFeed {
    case .posts:
      return savedPosts?.map { Either<Post, Comment>.first($0) }
    case .comments:
      return savedComments?.map { Either<Post, Comment>.second($0) }
    }
  }
  
  var body: some View {
    Group {
      if !isSavedSubreddit {
        Group {
          let filteredPosts = getFilteredPosts(posts: posts.data)
          
          if postPageDefSettings.useNativeCommentsView {
            PostsFeedNative(showSub: isFeedsAndSuch, feedStyleKey: subreddit.id, lastPostAfter: lastPostAfter, subreddit: subreddit, filters: filters, posts: filteredPosts, filter: filter, filterCallback: filterCallback, searchText: searchText, searchCallback: searchCallback, editCustomFilter: editCustomFilter, hideReadPosts: hideReadPosts, fetch: fetch, selectedTheme: selectedTheme, loading: loading, reachedEndOfFeed: $reachedEndOfFeed)
          } else if IPAD && hSizeClass == .regular {
            SubredditPostsIPAD(showSub: isFeedsAndSuch, feedStyleKey: subreddit.id, lastPostAfter: lastPostAfter, subreddit: subreddit, filters: filters, posts: filteredPosts, filter: filter, filterCallback: filterCallback, searchText: searchText, searchCallback: searchCallback, editCustomFilter: editCustomFilter, hideReadPosts: hideReadPosts, fetch: fetch, selectedTheme: selectedTheme, loading: loading, reachedEndOfFeed: $reachedEndOfFeed)
          } else {
            SubredditPostsIOS(showSub: isFeedsAndSuch, feedStyleKey: subreddit.id, lastPostAfter: lastPostAfter, subreddit: subreddit, filters: filters, posts: filteredPosts, filter: filter, filterCallback: filterCallback, searchText: searchText, searchCallback: searchCallback, editCustomFilter: editCustomFilter, hideReadPosts: hideReadPosts, fetch: fetch, selectedTheme: selectedTheme, loading: loading, reachedEndOfFeed: $reachedEndOfFeed)
          }
        }
        .searchable(text: $searchText, prompt: "Search r/\(subreddit.data?.display_name ?? subreddit.id)")
      } else {
        VStack(spacing: 0) {
          SavedFeedTabs(selection: $selectedSavedFeed)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

          if let savedMixedMediaLinks = savedMixedMediaLinks {
            MixedContentFeedView(mixedMediaLinks: savedMixedMediaLinks, loadNextData: $loadNextSavedData, subreddit: selectedSavedFeed == .posts ? nil : subreddit, reachedEndOfFeed: $reachedEndOfFeed)
              .onChange(of: loadNextSavedData) { shouldLoad in
                if shouldLoad {
                  fetch(shouldLoad)
                  loadNextSavedData = false
                }
              }
          } else if loading {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            SavedEmptyFeedView()
          }
        }
        .onChange(of: selectedSavedFeed) { tab in
          withAnimation {
            loadNextSavedData = false
            loading = tab == .posts ? savedPosts == nil : savedComments == nil
            reachedEndOfFeed = tab == .posts ? savedPostsReachedEnd : savedCommentsReachedEnd
          }
          switch tab {
          case .posts:
            if savedPosts == nil { fetch(false) }
          case .comments:
            if savedComments == nil { fetch(false) }
          }
        }
      }
    }
    .onAppear {
      if !hasViewLoaded {
        isSavedSubreddit = subreddit.id == "saved" // detect unique saved subreddit (saved posts and comments require unique logic)
        resetHiddenPosts()
        hasViewLoaded = true
      }
    }
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden)
    .environment(\.defaultMinListRowHeight, 1)
//    .overlay(
//      isFeedsAndSuch
//      ? nil
//      : Button {
//        newPost = true
//      } label: {
//        Image(systemName: "newspaper.fill")
//          .fontSize(22, .bold)
//          .frame(width: 64, height: 64)
//          .foregroundColor(Color.accentColor)
//          .floating()
//          .contentShape(Circle())
//      }
//        .buttonStyle(NoBtnStyle())
//        .shrinkOnTap()
//        .padding(.all, 12)
//      , alignment: .bottomTrailing
//    )
    // TODO(graphql): post composer is disabled — only a CreateSubredditPost
    // (text) operation is captured so far; link/image/gallery submission has
    // no GraphQL surface yet.
    //    .sheet(isPresented: $newPost, content: {
    //      NewPostModal(subreddit: subreddit)
    //    })
    .navigationBarItems(trailing: SubredditPostsNavBtns(sort: $sort, subreddit: subreddit))
    .onSubmit(of: .search) {
      clearAndLoadData(withSearchText: searchText)
    }
    .refreshable {
      clearAndLoadData(forceRefresh: true)
    }
    .navigationTitle("\(isFeedsAndSuch ? subreddit.id.capitalized : "r/\(subreddit.data?.display_name ?? subreddit.id)")")
    .task(priority: .background) {
      if posts.data.count == 0 && (savedMixedMediaLinks?.count == 0 || savedMixedMediaLinks == nil) {
        fetch()
      }
    }
    .onChange(of: sort) { val in
      clearAndLoadData(forceRefresh: true)
    }
//    .onChange(of: cs) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: subredditFeedDefSettings.compactPerSubreddit) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: subredditFeedDefSettings.postStylePerSubreddit) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: postLinkDefSettings) { _ in updatePostsCalcs(selectedTheme) }
    .onChange(of: selectedTheme, perform: updatePostsCalcs)
    .onChange(of: searchText) { val in if searchText.isEmpty { clearAndLoadData() } }
    .sheet(item: $customFilter, onDismiss: {
      self.subreddit.loadFlairs( { loaded in
        filters = loaded
      })
    }) { custom in
      CustomFilterView(filter: custom, subId: subreddit.id, selected: $filter)
    }
  }
  
}

private struct SavedFeedTabs: View {
  @Binding var selection: SavedFeedTab

  var body: some View {
    Picker("Saved content", selection: $selection) {
      ForEach(SavedFeedTab.allCases) { tab in
        Text(tab.rawValue).tag(tab)
      }
    }
    .pickerStyle(.segmented)
  }
}

private struct SavedEmptyFeedView: View {
  @Environment(\.useTheme) private var selectedTheme

  var body: some View {
    List {
      Section {
        EndOfFeedView()
      }
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .environment(\.defaultMinListRowHeight, 1)
    }
    .themedListBG(selectedTheme.postLinks.bg)
    .scrollContentBackground(.hidden)
    .scrollIndicators(.never)
    .listStyle(.plain)
  }
}


struct SubredditPostsNavBtns: View, Equatable {
  static func == (lhs: SubredditPostsNavBtns, rhs: SubredditPostsNavBtns) -> Bool {
    lhs.sort == rhs.sort && (lhs.subreddit.data == nil) == (rhs.subreddit.data == nil)
  }
  @Binding var sort: SubListingSortOption
  @ObservedObject var subreddit: Subreddit
  var body: some View {
    HStack {
      Menu {
        ForEach(SubListingSortOption.allCases) { opt in
          if case .top(_) = opt {
            Menu {
              ForEach(SubListingSortOption.TopListingSortOption.allCases, id: \.self) { topOpt in
                Button {
                  sort = .top(topOpt)
//                  Defaults[.subredditSorts][subreddit.id] = .top(topOpt)
                  Defaults[.SubredditFeedDefSettings].subredditSorts[subreddit.id] = .top(topOpt)
                } label: {
                  HStack {
                    Text(topOpt.rawValue.capitalized)
                    Spacer()
                    Image(systemName: topOpt.icon)
                      .foregroundColor(Color.accentColor)
                      .font(.system(size: 17, weight: .bold))
                  }
                }
              }
            } label: {
              Label(opt.rawVal.value.capitalized, systemImage: opt.rawVal.icon)
                .foregroundColor(Color.accentColor)
                .font(.system(size: 17, weight: .bold))
            }
          } else {
            Button {
              sort = opt
              Defaults[.SubredditFeedDefSettings].subredditSorts[subreddit.id] = opt
            } label: {
              HStack {
                Text(opt.rawVal.value.capitalized)
                Spacer()
                Image(systemName: opt.rawVal.icon)
                  .foregroundColor(Color.accentColor)
                  .font(.system(size: 17, weight: .bold))
              }
            }
          }
        }
      } label: {
        Image(systemName: sort.rawVal.icon)
          .foregroundColor(Color.accentColor)
          .fontSize(17, .bold)
      }
      .disabled(subreddit.id == "saved")
      
      if let data = subreddit.data {
        Button {
          Nav.to(.reddit(.subInfo(subreddit)))
        } label: {
          SubredditIcon(subredditIconKit: data.subredditIconKit)
        }
      }
    }
    .animation(nil, value: sort)
  }
}
