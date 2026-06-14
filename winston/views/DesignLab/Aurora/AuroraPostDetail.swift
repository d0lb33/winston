//
//  AuroraPostDetail.swift
//  winston
//
//  Aurora — the trailing (detail) column: a real post + threaded comments.
//
//  This is the iOS-27 native comment engine (CommentTreeModel flatten-and-diff,
//  CommentsTreeView) re-skinned with Aurora glass chrome: a glass action bar and
//  composer batched as live-blur (fixed chrome, never scrolled), the mesh backdrop
//  showing through a hidden List background, and depth-tinted thread rails. The post
//  header (title / media / body / crosspost) reuses the production PostHeaderNative,
//  so all media — images, inline video, galleries, link cards — comes through the
//  real MediaPresenter pipeline untouched.
//

import SwiftUI
import Defaults

struct AuroraPostDetail: View {
  @ObservedObject var post: Post
  var subreddit: Subreddit
  var highlightID: String?

  @State private var model = CommentTreeModel()
  @State private var sort: CommentSortOption
  @State private var loadingComments = true
  @State private var isFetching = false
  @State private var pendingHighlight: String? = nil
  /// When viewing a single comment by id, the user can expand to the full post.
  @State private var showingAllComments = false

  /// Capped inline-media height + swipe-anywhere, read ONCE here (both are codable
  /// Defaults values → each access JSON-decodes the whole struct) and threaded down.
  private let maxMediaHeightPct: CGFloat
  private let swipeAnywhere: Bool

  @Default(.CommentLinkDefSettings) private var commentDefSettings
  @Environment(\.useTheme) private var selectedTheme
  @Environment(\.auroraTheme) private var theme

  init(post: Post, subreddit: Subreddit, highlightID: String? = nil) {
    self.post = post
    self.subreddit = subreddit
    self.highlightID = highlightID
    self.maxMediaHeightPct = min(Defaults[.PostLinkDefSettings].maxMediaHeightScreenPercentage, 45)
    self.swipeAnywhere = Defaults[.BehaviorDefSettings].enableSwipeAnywhere

    let defSettings = Defaults[.PostPageDefSettings]
    let commentsDefSettings = Defaults[.CommentsSectionDefSettings]
    _sort = State(initialValue: defSettings.perPostSort ? (defSettings.postSorts[post.id] ?? commentsDefSettings.preferredSort) : commentsDefSettings.preferredSort)
  }

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
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
          }
          auroraActionBar
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        Section {
          if isSingleThread { viewAllCommentsBanner }
          CommentsTreeView(
            model: model,
            loading: loadingComments,
            post: post,
            postFullname: post.data?.name ?? "",
            opAuthor: post.data?.author,
            swipeActions: commentDefSettings.swipeActions,
            swipeAnywhere: swipeAnywhere,
            maxMediaHeightPct: maxMediaHeightPct
          )
        } header: {
          if !model.rows.isEmpty {
            Text(commentsHeaderTitle).font(.headline).foregroundStyle(.primary).textCase(nil)
          }
        }
        .listRowBackground(Color.clear)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .navigationTitle(navTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { sortToolbar }
      .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
      .safeAreaInset(edge: .bottom) { composer }
      .refreshable { await fetch(true) }
      .task {
        ensureWinston()
        if model.rows.isEmpty || post.data == nil {
          await fetch(post.data == nil)
        }
      }
      .onChange(of: sort) { _, _ in
        Defaults[.PostPageDefSettings].postSorts[post.id] = sort
        Task { await fetch(true) }
      }
      .onChange(of: model.rows.count) { _, _ in
        guard let target = pendingHighlight else { return }
        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
        pendingHighlight = nil
      }
      .onReceive(ReplyModalInstance.shared.$isShowing) { showing in
        if showing == .none { withAnimation { model.rebuild() } }
      }
    }
  }

  private var commentsHeaderTitle: String {
    if isSingleThread { return "Thread" }
    return "\(post.data?.num_comments ?? model.rows.count) Comments"
  }

  // MARK: - Glass action bar (chrome — live glass is fine, it never scrolls inside the list)

  @ViewBuilder private var auroraActionBar: some View {
    if let data = post.data {
      GlassEffectContainer(spacing: 12) {
        HStack(spacing: 12) {
          GlassVotePill(
            likes: data.likes,
            score: data.ups,
            onUp: { _ = await post.vote(.up) },
            onDown: { _ = await post.vote(.down) }
          )

          Label(formatBigNumber(data.num_comments), systemImage: "bubble.left.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)

          Spacer()

          glassCircleButton(data.saved ? "bookmark.fill" : "bookmark", tint: data.saved ? theme.accent : .secondary) {
            Task { _ = await post.saveToggle() }
          }
          glassCircleButton("arrowshape.turn.up.left", tint: .secondary) {
            ReplyModalInstance.shared.enable(.post(post))
          }
          if let permaURL = URL(string: "https://reddit.com\(data.permalink.escape.urlEncoded)") {
            ShareLink(item: permaURL) {
              Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(11)
                .glassEffect(.regular.interactive(), in: .circle)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func glassCircleButton(_ symbol: String, tint: Color, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .padding(11)
        .glassEffect(.regular.interactive(), in: .circle)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Glass composer

  private var composer: some View {
    HStack(spacing: 10) {
      AuroraAvatar(name: RedditWire.shared.me?.data?.name ?? "you", size: 28)
      Text("Add a comment…").font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Image(systemName: "paperplane.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.accent)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.horizontal, 16).padding(.bottom, 8)
    .contentShape(Capsule())
    .onTapGesture { ReplyModalInstance.shared.enable(.post(post)) }
  }

  private var viewAllCommentsBanner: some View {
    Button {
      withAnimation { showingAllComments = true }
      pendingHighlight = nil
      Task { await fetch(post.data == nil) }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.title3).foregroundStyle(theme.accent)
        VStack(alignment: .leading, spacing: 1) {
          Text("Viewing a single thread").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
          Text("Tap to load the full discussion").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ToolbarContentBuilder private var sortToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Picker("Sort Comments", selection: $sort) {
          ForEach(CommentSortOption.allCases) { opt in
            Label(opt.rawVal.value.capitalized, systemImage: opt.rawVal.icon).tag(opt)
          }
        }
      } label: {
        Image(systemName: sort.rawVal.icon)
      }
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

    let commentID = effectiveCommentID
    let result = await post.refreshPost(commentID: commentID, sort: sort, after: nil, subreddit: subreddit.data?.display_name ?? subreddit.id, full: full)
    print("AURORA_POST fetch post=\(post.id) sub=\(subreddit.id) full=\(full) → \(result == nil ? "result=nil" : "comments=\(result?.0?.count ?? -1)")")
    if let result, let newComments = result.0 {
      withAnimation {
        model.setRoots(newComments)
        loadingComments = false
      }
      print("AURORA_POST setRoots post=\(post.id) model.rows=\(model.rows.count)")
      if let commentID {
        pendingHighlight = commentID.hasPrefix("t1_") ? String(commentID.dropFirst(3)) : commentID
      }
    } else {
      withAnimation { loadingComments = false }
    }
  }
}
