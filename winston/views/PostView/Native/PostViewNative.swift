//
//  PostViewNative.swift
//  winston
//
//  iOS 27 native rebuild of the post detail screen. One plain List: the post
//  header + action bar, then the flattened comment rows. No artificial reveal
//  delay, no faked card-corner decoration rows, no recursive views in the List,
//  and crucially no whole-List re-render on every background avatar update (the
//  comment forest is owned by CommentTreeModel, not observed here).
//
//  Native post + comments screen used by the Aurora navigation flow.
//

import SwiftUI
import Defaults

struct PostViewNative: View {
  @ObservedObject var post: Post
  var subreddit: Subreddit
  var highlightID: String?

  @State private var model: CommentTreeModel
  @State private var sort: CommentSortOption
  @State private var loadingComments = true
  @State private var commentLoadError: String? = nil
  @State private var isFetching = false
  @State private var pendingHighlight: String? = nil
  /// When viewing a single comment by id, the user can expand to the full post.
  @State private var showingAllComments = false

  /// Capped inline-media height, read ONCE here (PostLinkDefSettings is a codable
  /// Defaults value → each access JSON-decodes the whole struct). Threaded down as a
  /// plain CGFloat so comment rows never decode it per-row during scroll.
  private let maxMediaHeightPct: CGFloat

  @Default(.CommentLinkDefSettings) private var commentDefSettings
  @Environment(\.useTheme) private var selectedTheme

  init(post: Post, subreddit: Subreddit, highlightID: String? = nil) {
    self.post = post
    self.subreddit = subreddit
    self.highlightID = highlightID
    self.maxMediaHeightPct = min(Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage, 45)

    let defSettings = Defaults[.PostPageDefSettings]
    let commentsDefSettings = Defaults[.CommentsSectionDefSettings]
    _model = State(initialValue: CommentTreeModel(postID: post.id))
    _sort = State(initialValue: defSettings.perPostSort ? (defSettings.postSorts[post.id] ?? commentsDefSettings.preferredSort) : commentsDefSettings.preferredSort)
  }

  /// The comment context we actually fetch — nil once the user asks for the full post.
  private var effectiveCommentID: String? { showingAllComments ? nil : highlightID }
  private var isSingleThread: Bool { highlightID != nil && !showingAllComments }
  private var navTitle: String { "r/\(post.data?.subreddit ?? subreddit.id)" }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        Section {
          if let winstonData = post.winstonData {
            PostHeaderNative(post: post, winstonData: winstonData, sub: subreddit)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: 200)
          }
          PostActionBarNative(post: post, updateComments: appendReplyComment)
        }
        .listRowSeparator(.hidden)

        Section {
          if isSingleThread {
            viewAllCommentsBanner
          }
            CommentsTreeView(
              model: model,
              loading: loadingComments,
              errorMessage: commentLoadError,
              post: post,
            postFullname: post.data?.name ?? "",
            opAuthor: post.data?.author,
            swipeActions: commentDefSettings.swipeActions,
            maxMediaHeightPct: maxMediaHeightPct
          )
        } header: {
          if !model.rows.isEmpty {
            Text(commentsHeaderTitle)
              .font(.headline)
              .foregroundStyle(.primary)
              .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      .navigationTitle(navTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { sortToolbar }
      .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
      .refreshable { await fetch(true) }
      .onAppear {
        ensureWinston()
        if model.rows.isEmpty || post.data == nil {
          Task { await fetch(post.data == nil) }
        }
      }
      .onChange(of: sort) { _, _ in
        Defaults[.PostPageDefSettings].postSorts[post.id] = sort
        Task { await fetch(true) }
      }
      .onChange(of: model.rows.count) { _, _ in
        if let target = pendingHighlight {
          withAnimation(spring) { proxy.scrollTo(target, anchor: .center) }
          pendingHighlight = nil
        }
      }
      // A reply/edit posted through the global modal mutates the comment tree;
      // rebuild when it dismisses so the new comment shows without a refetch.
      .onReceive(ReplyModalInstance.shared.$isShowing) { showing in
        if showing == .none { withAnimation { model.rebuild() } }
      }
    }
  }

  private var commentsHeaderTitle: String {
    if isSingleThread { return "Thread" }
    return "\(post.data?.num_comments ?? model.rows.count) Comments"
  }

  private var viewAllCommentsBanner: some View {
    Button {
      withAnimation { showingAllComments = true }
      pendingHighlight = nil
      Task { await fetch(post.data == nil) }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.title3)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text("Viewing a single thread")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text("Tap to load the full discussion")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowSeparator(.hidden)
  }

  @ToolbarContentBuilder private var sortToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      CommentSortMenu(selection: $sort)
    }
  }

  private func ensureWinston() {
    if let data = post.data, post.winstonData == nil || post.winstonData?.titleAttr == nil {
      post.setupWinstonData(data: data, theme: selectedTheme, sub: subreddit)
    }
  }

  @MainActor
  private func fetch(_ full: Bool) async {
    guard !isFetching else { return }
    isFetching = true
    defer { isFetching = false }
    if model.rows.isEmpty {
      loadingComments = true
    }
    commentLoadError = nil

    let commentID = effectiveCommentID
    switch await post.refreshPostResult(commentID: commentID, sort: sort, after: nil, subreddit: subreddit.data?.display_name ?? subreddit.id, full: full) {
    case .loaded(let newComments, _):
      withAnimation {
        model.setRoots(newComments)
        loadingComments = false
      }
      if let commentID {
        pendingHighlight = commentID.hasPrefix("t1_") ? String(commentID.dropFirst(3)) : commentID
      }
    case .empty:
      withAnimation {
        model.setRoots([])
        loadingComments = false
      }
    case .transientEmpty(_), .failed(_):
      withAnimation {
        commentLoadError = "Pull to refresh and try loading comments again."
        loadingComments = false
      }
    }
  }

  private func appendReplyComment(_ comment: Comment) {
    guard !model.rootArray.data.contains(where: { $0.id == comment.id }) else { return }
    comment.parentWinston = model.rootArray
    model.rootArray.data.append(comment)
    withAnimation {
      loadingComments = false
      model.rebuild(force: true)
    }
  }
}
