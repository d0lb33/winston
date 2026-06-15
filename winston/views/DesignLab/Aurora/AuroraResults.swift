//
//  AuroraResults.swift
//  winston
//
//  Shared Aurora result rows for Search and Saved.
//

import SwiftUI

struct AuroraResultSectionHeader: View {
  let title: LocalizedStringKey
  let count: Int?

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.primary)
      if let count {
        Text("\(count)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.accent)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(theme.chipFill, in: .capsule)
      }
    }
    .textCase(nil)
  }
}

struct AuroraLoadMoreFooter: View {
  let loading: Bool

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
    .frame(minHeight: 42)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

struct AuroraPostResultRow: View {
  let post: Post
  let select: (Post) -> Void

  var body: some View {
    AuroraCard(post: post)
      .contentShape(Rectangle())
      .onTapGesture {
        select(post)
      }
  }
}

struct AuroraCommentResultRow: View {
  @ObservedObject var comment: Comment
  let select: (Comment) -> Void

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    if let data = comment.data {
      Button {
        select(comment)
      } label: {
        VStack(alignment: .leading, spacing: 11) {
          HStack(spacing: 8) {
            AuroraAvatar(name: data.author ?? "u", size: 24)
            Text("u/\(data.author ?? "[deleted]")")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text("· \(Date(timeIntervalSince1970: data.created ?? data.created_utc ?? 0), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if data.saved == true {
              Image(systemName: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)
            }
          }

          if let title = data.link_title, !title.isEmpty {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }

          if let body = data.body, !body.isEmpty {
            Text(body)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(5)
              .multilineTextAlignment(.leading)
          }

          HStack(spacing: 12) {
            if let subreddit = data.subreddit, !subreddit.isEmpty {
              Label("r/\(subreddit)", systemImage: "rectangle.stack")
            }
            Label(formatBigNumber(data.ups ?? data.score ?? 0), systemImage: "arrow.up")
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .stroke(theme.hairline, lineWidth: 0.7)
        )
      }
      .buttonStyle(.plain)
    }
  }
}

struct AuroraCommunityResultRow: View {
  @ObservedObject var subreddit: Subreddit
  let select: (Subreddit) -> Void

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    Button {
      select(subreddit)
    } label: {
      HStack(spacing: 12) {
        AuroraSubIcon(name: subreddit.data?.display_name ?? subreddit.id, iconKit: subreddit.data?.subredditIconKit, size: 38)
        VStack(alignment: .leading, spacing: 3) {
          Text(subreddit.displayTitle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let members = subreddit.data?.subscribers, members > 0 {
            Text("\(formatBigNumber(members)) members")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let description = subreddit.data?.public_description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(theme.hairline, lineWidth: 0.7)
      )
    }
    .buttonStyle(.plain)
    .task {
      if subreddit.needsAuroraMetadataRefresh {
        await subreddit.refreshSubreddit()
      }
    }
  }
}

struct AuroraUserResultRow: View {
  @ObservedObject var user: User
  let select: (User) -> Void

  @Environment(\.auroraTheme) private var theme

  var body: some View {
    Button {
      select(user)
    } label: {
      HStack(spacing: 12) {
        AuroraAvatar(name: user.data?.name ?? user.id, size: 38)
        VStack(alignment: .leading, spacing: 3) {
          Text("u/\(user.data?.name ?? user.id)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          let karma = user.data?.total_karma ?? ((user.data?.link_karma ?? 0) + (user.data?.comment_karma ?? 0))
          Text("\(formatBigNumber(karma)) karma")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let description = user.data?.subreddit?.public_description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(theme.hairline, lineWidth: 0.7)
      )
    }
    .buttonStyle(.plain)
  }
}

@MainActor
@Observable
final class AuroraSavedModel {
  private(set) var posts: [Post] = []
  private(set) var comments: [Comment] = []
  private(set) var loadingPosts = false
  private(set) var loadingComments = false
  private(set) var failedPosts = false
  private(set) var failedComments = false

  @ObservationIgnored private var postAfter: String?
  @ObservationIgnored private var commentAfter: String?
  @ObservationIgnored private var loadedPostIDs: Set<String> = []
  @ObservationIgnored private var loadedCommentIDs: Set<String> = []
  @ObservationIgnored private var postsInFlight = false
  @ObservationIgnored private var commentsInFlight = false
  @ObservationIgnored private var loadGeneration = 0

  var loadingInitial: Bool {
    (loadingPosts || loadingComments) && posts.isEmpty && comments.isEmpty
  }

  var isEmpty: Bool {
    posts.isEmpty && comments.isEmpty
  }

  var canLoadMorePosts: Bool {
    postAfter != nil
  }

  var canLoadMoreComments: Bool {
    commentAfter != nil
  }

  func loadInitialIfNeeded(contentWidth: CGFloat) async {
    guard posts.isEmpty, comments.isEmpty, !postsInFlight, !commentsInFlight else { return }
    await reload(contentWidth: contentWidth)
  }

  func reload(contentWidth: CGFloat) async {
    reset()
    await loadPosts(more: false, contentWidth: contentWidth)
    await loadComments(more: false)
  }

  func reset() {
    postAfter = nil
    commentAfter = nil
    loadedPostIDs.removeAll(keepingCapacity: true)
    loadedCommentIDs.removeAll(keepingCapacity: true)
    posts = []
    comments = []
    loadingPosts = false
    loadingComments = false
    failedPosts = false
    failedComments = false
    postsInFlight = false
    commentsInFlight = false
    loadGeneration += 1
  }

  func resetForAccountSwitch() {
    withAnimation {
      reset()
    }
  }

  func loadMorePosts(contentWidth: CGFloat) async {
    guard canLoadMorePosts else { return }
    await loadPosts(more: true, contentWidth: contentWidth)
  }

  func loadMoreComments() async {
    guard canLoadMoreComments else { return }
    await loadComments(more: true)
  }

  private func loadPosts(more: Bool, contentWidth: CGFloat) async {
    guard !postsInFlight else { return }
    let generation = loadGeneration
    postsInFlight = true
    loadingPosts = true
    failedPosts = false
    defer { postsInFlight = false; loadingPosts = false }

    let saved = Subreddit(id: "saved")
    guard let response = await saved.fetchSavedPosts(after: more ? postAfter : nil, contentWidth: max(1, contentWidth)),
          let newPosts = response.0 else {
      guard generation == loadGeneration else { return }
      failedPosts = posts.isEmpty
      return
    }
    guard generation == loadGeneration else { return }

    let fresh = more ? newPosts.filter { loadedPostIDs.insert($0.id).inserted } : newPosts.deduped { $0.id }
    if !more {
      loadedPostIDs = Set(fresh.map(\.id))
    }

    withAnimation {
      if more {
        posts.append(contentsOf: fresh)
      } else {
        posts = fresh
      }
    }
    postAfter = response.1
  }

  private func loadComments(more: Bool) async {
    guard !commentsInFlight else { return }
    let generation = loadGeneration
    commentsInFlight = true
    loadingComments = true
    failedComments = false
    defer { commentsInFlight = false; loadingComments = false }

    let saved = Subreddit(id: "saved")
    guard let response = await saved.fetchSavedComments(after: more ? commentAfter : nil),
          let newComments = response.0 else {
      guard generation == loadGeneration else { return }
      failedComments = comments.isEmpty
      return
    }
    guard generation == loadGeneration else { return }

    let fresh = more ? newComments.filter { loadedCommentIDs.insert($0.id).inserted } : newComments.deduped { $0.id }
    if !more {
      loadedCommentIDs = Set(fresh.map(\.id))
    }

    withAnimation {
      if more {
        comments.append(contentsOf: fresh)
      } else {
        comments = fresh
      }
    }
    commentAfter = response.1
  }
}

struct AuroraSavedScreen: View {
  let onPostSelected: (Post) -> Void
  let onCommentSelected: (Comment) -> Void

  @State private var model = AuroraSavedModel()
  @ObservedObject private var wire = RedditWire.shared
  @Environment(\.contentWidth) private var contentWidth

  var body: some View {
    List {
      if !model.posts.isEmpty {
        Section(header: AuroraResultSectionHeader(title: "Posts", count: model.posts.count)) {
          ForEach(model.posts) { post in
            AuroraPostResultRow(post: post, select: onPostSelected)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
              .onAppear {
                if post.id == model.posts.last?.id {
                  Task { await model.loadMorePosts(contentWidth: contentWidth) }
                }
              }
          }
          if model.canLoadMorePosts {
            AuroraLoadMoreFooter(loading: model.loadingPosts)
              .onAppear {
                Task { await model.loadMorePosts(contentWidth: contentWidth) }
              }
          }
        }
      }

      if !model.comments.isEmpty {
        Section(header: AuroraResultSectionHeader(title: "Comments", count: model.comments.count)) {
          ForEach(model.comments) { comment in
            AuroraCommentResultRow(comment: comment, select: onCommentSelected)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
              .onAppear {
                if comment.id == model.comments.last?.id {
                  Task { await model.loadMoreComments() }
                }
              }
          }
          if model.canLoadMoreComments {
            AuroraLoadMoreFooter(loading: model.loadingComments)
              .onAppear {
                Task { await model.loadMoreComments() }
              }
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .navigationTitle("Saved")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.reload(contentWidth: contentWidth) }
    .overlay { emptyState }
    .task {
      await model.loadInitialIfNeeded(contentWidth: contentWidth)
    }
    .onChange(of: wire.accountScopeID) { _, _ in
      model.resetForAccountSwitch()
      Task {
        await model.reload(contentWidth: contentWidth)
      }
    }
  }

  @ViewBuilder private var emptyState: some View {
    if model.loadingInitial {
      ProgressView()
    } else if model.isEmpty && (model.failedPosts || model.failedComments) {
      ContentUnavailableView {
        Label("Couldn't load saved items", systemImage: "wifi.exclamationmark")
      } description: {
        Text("Pull to try again.")
      }
    } else if model.isEmpty {
      ContentUnavailableView("No saved items", systemImage: "bookmark")
    }
  }
}
