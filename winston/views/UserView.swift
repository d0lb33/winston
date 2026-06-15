//
//  UserView.swift
//  winston
//
//  Created by Igor Marcossi on 01/07/23.
//

import SwiftUI
import NukeUI
import Defaults

struct UserViewContextPreview: View {
  var author: String
  var body: some View {
    NavigationStack { UserView(user: User(id: author)) }
  }
}

struct UserView: View {
  @StateObject var user: User
  @State private var lastActivities: [Either<Post, Comment>]?
  @State private var contentWidth: CGFloat = 0
  @State private var loadingOverview = true
  @State private var loadingNextOverview = false
  @State private var reachedEndOfOverview = false
  @State private var lastItemId: String? = nil
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  
  @State private var dataTypeFilter: String = "" // Handles filtering for only posts or only comments.

  private var canPageOverview: Bool {
    dataTypeFilter == "posts" || dataTypeFilter == "comments"
  }
  
  func refresh() async {
    await user.refetchUser()
    if let data = await user.refetchOverview(dataTypeFilter) {
      await MainActor.run {
        withAnimation {
          loadingOverview = false
          loadingNextOverview = false
          lastActivities = data
          reachedEndOfOverview = data.isEmpty || !canPageOverview
          lastItemId = canPageOverview ? data.last.map { getItemId(for: $0) } : nil
        }
      }
      
      await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: data, avatarSize: AuroraPostPresentation.avatarSize)
    } else {
      await MainActor.run {
        withAnimation {
          loadingOverview = false
          loadingNextOverview = false
          reachedEndOfOverview = true
          lastItemId = nil
        }
      }
    }
  }
  
  func getNextData() {
    guard canPageOverview, !loadingOverview, !loadingNextOverview, !reachedEndOfOverview, let lastId = lastItemId else { return }
    loadingNextOverview = true
    Task {
      if let overviewData = await user.refetchOverview(dataTypeFilter, lastId) {
        await MainActor.run {
          withAnimation {
            if overviewData.isEmpty {
              reachedEndOfOverview = true
              lastItemId = nil
            } else {
              lastActivities?.append(contentsOf: overviewData)
              lastItemId = overviewData.last.map { getItemId(for: $0) }
            }
            loadingNextOverview = false
          }
        }
        
        if !overviewData.isEmpty {
          await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: overviewData, avatarSize: AuroraPostPresentation.avatarSize)
        }
      } else {
        await MainActor.run {
          withAnimation {
            loadingNextOverview = false
            reachedEndOfOverview = true
            lastItemId = nil
          }
        }
      }
    }
  }
  
  var body: some View {
    List {
      if let data = user.data {
        UserProfileHeader(data: data, contentWidth: $contentWidth)
          .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)

        UserProfileMetrics(data: data, filter: $dataTypeFilter)
          .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)

        UserActivityHeader(filter: dataTypeFilter)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)

        if let lastActivities {
          ForEach(Array(lastActivities.enumerated()), id: \.element) { i, item in
            UserActivityRow(item: item)
              .onAppear {
                if i >= max(lastActivities.count - 7, 0) {
                  getNextData()
                }
              }
              .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
          }

          if lastActivities.isEmpty && !loadingOverview {
            UserActivityEmptyState()
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
          }
        }

        if loadingOverview || loadingNextOverview {
          UserActivityLoadingState()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else if reachedEndOfOverview && canPageOverview && lastActivities?.isEmpty == false {
          EndOfFeedView()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
      }
    }
    .loader(user.data == nil)
    .auroraListChrome()
    .refreshable {
      await refresh()
    }
    .navigationTitle(user.data?.name ?? "Loading...")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      Task(priority: .background) {
        if user.data == nil || lastActivities == nil {
          await refresh()
        }
      }
    }
    .onChange(of: dataTypeFilter) {
      withAnimation {
        lastActivities?.removeAll()
        loadingOverview = true
        loadingNextOverview = false
        reachedEndOfOverview = false
        lastItemId = nil
      }
      
      Task {
        await refresh()
      }
    }
  }
}

private struct UserProfileHeader: View {
  let data: UserData
  @Binding var contentWidth: CGFloat
  @Environment(\.auroraTheme) private var theme

  private var hasBanner: Bool {
    data.subreddit?.banner_img?.isEmpty == false
  }

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if let bannerImgFull = data.subreddit?.banner_img, !bannerImgFull.isEmpty, let bannerImg = URL(string: String(bannerImgFull.split(separator: "?")[0])) {
          URLImage(url: bannerImg)
            .scaledToFill()
            .frame(width: contentWidth, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .fill(theme.cardFill)
            .frame(height: 92)
        }

        if let iconFull = data.subreddit?.icon_img, !iconFull.isEmpty, let icon = URL(string: String(iconFull.split(separator: "?")[0])) {
          URLImage(url: icon)
            .scaledToFill()
            .frame(width: 124, height: 124)
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .offset(y: hasBanner ? 80 : 0)
        } else {
          AuroraAvatar(name: data.name, size: 124)
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .offset(y: hasBanner ? 80 : 0)
        }
      }
      .frame(maxWidth: .infinity)
      .background(
        GeometryReader { geo in
          Color.clear.onAppear { contentWidth = geo.size.width }
        }
      )
      .padding(.bottom, hasBanner ? 76 : 0)

      VStack(spacing: 6) {
        Text("u/\(data.name)")
          .font(.title3.weight(.bold))
        if let description = data.subreddit?.public_description, !description.isEmpty {
          Text(description.md())
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 8)
    }
  }
}

private struct UserProfileMetrics: View {
  let data: UserData
  @Binding var filter: String

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        if let postKarma = data.link_karma {
          AuroraMetricTile(
            icon: "highlighter",
            label: "Post karma",
            value: formatBigNumber(postKarma),
            active: filter == "posts"
          ) {
            toggle("posts")
          }
        }

        if let commentKarma = data.comment_karma {
          AuroraMetricTile(
            icon: "checkmark.message.fill",
            label: "Comment karma",
            value: formatBigNumber(commentKarma),
            active: filter == "comments"
          ) {
            toggle("comments")
          }
        }
      }

      if let created = data.created {
        AuroraMetricTile(
          icon: "star.fill",
          label: "User since",
          value: Date(timeIntervalSince1970: TimeInterval(created)).toFormat("MMM dd, yyyy")
        )
      }
    }
  }

  private func toggle(_ value: String) {
    withAnimation(.easeInOut(duration: 0.2)) {
      filter = filter == value ? "" : value
    }
  }
}

private struct UserActivityHeader: View {
  let filter: String

  var body: some View {
    Text(filter.isEmpty ? "Latest activity" : "Latest \(filter)")
      .font(.headline.weight(.semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct UserActivityRow: View {
  let item: Either<Post, Comment>
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  var body: some View {
    switch item {
    case .first(let post):
      AuroraPostResultRow(post: post, availableRowWidth: nil) { post in
        navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
      }
    case .second(let comment):
      AuroraCommentResultRow(comment: comment) { comment in
        openCommentPost(comment)
      }
      .padding(.horizontal, 14)
    }
  }

  private func openCommentPost(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    navigateRedditDestination(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)), model: redditNavigationModel, origin: redditNavigationOrigin)
  }
}

private struct UserActivityEmptyState: View {
  var body: some View {
    ContentUnavailableView("No activity found", systemImage: "tray")
      .frame(maxWidth: .infinity, minHeight: 160)
  }
}

private struct UserActivityLoadingState: View {
  var body: some View {
    HStack {
      Spacer()
      ProgressView()
        .progressViewStyle(.circular)
      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 100)
  }
}

//struct UserView_Previews: PreviewProvider {
//    static var previews: some View {
//        UserView()
//    }
//}
