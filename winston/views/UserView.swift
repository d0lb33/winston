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
  @Environment(\.useTheme) private var selectedTheme
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  
  @State private var dataTypeFilter: String = "" // Handles filtering for only posts or only comments.
  @State private var loadNextData: Bool = false
  
  @ObservedObject var avatarCache = Caches.avatars
  //  @Environment(\.contentWidth) private var contentWidth

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
      
      await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: data, avatarSize: selectedTheme.postLinks.theme.badge.avatar.size)
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
          await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: overviewData, avatarSize: selectedTheme.postLinks.theme.badge.avatar.size)
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
  
  func getRepostAvatarRequest(_ post: Post?) -> ImageRequest? {
    if let post = post, case .repost(let repost) = post.winstonData?.extractedMedia, let repostAuthorFullname = repost.data?.author_fullname {
      return avatarCache.cache[repostAuthorFullname]?.data
    }
    return nil
  }
  
  var body: some View {
    List {
      if let data = user.data {
        Group {
          VStack(spacing: 16) {
            ZStack {
              if let bannerImgFull = data.subreddit?.banner_img, !bannerImgFull.isEmpty, let bannerImg = URL(string: String(bannerImgFull.split(separator: "?")[0])) {
                URLImage(url: bannerImg)
                  .scaledToFill()
                  .frame(width: contentWidth, height: 160)
                  .mask(RR(16, Color.black))
              }
              if let iconFull = data.subreddit?.icon_img, iconFull != "", let icon = URL(string: String(iconFull.split(separator: "?")[0])) {
                
                URLImage(url: icon)
                  .scaledToFill()
                  .frame(width: 125, height: 125)
                  .mask(Circle())
                  .offset(y: data.subreddit?.banner_img == "" || data.subreddit?.banner_img == nil ? 0 : 80)
              }
            }
            .frame(maxWidth: .infinity)
            .background(
              GeometryReader { geo in
                Color.clear.onAppear { contentWidth = geo.size.width }
              }
            )
            .padding(.bottom, data.subreddit?.banner_img == "" || data.subreddit?.banner_img == nil ? 0 : 78)
            
            if let description = data.subreddit?.public_description {
              Text((description).md())
                .fontSize(15)
                .multilineTextAlignment(.center)
            }
            
            VStack {
              HStack {
                if let postKarma = data.link_karma {
                  DataBlock(icon: "highlighter", label: "Post karma",
                            value: "\(formatBigNumber(postKarma))") // maybe switch this to use the theme colors?
                  .transition(.opacity)
                  .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                      if dataTypeFilter == "posts" {
                        dataTypeFilter = ""
                      } else {
                        dataTypeFilter = "posts"
                      }
                    }
                  }
                  .overlay(dataTypeFilter == "posts" ?
                           Color.accentColor.opacity(0.2)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .allowsHitTesting(false)
                           : nil)
                }
                
                if let commentKarma = data.comment_karma {
                  DataBlock(icon: "checkmark.message.fill", label: "Comment karma", value: "\(formatBigNumber(commentKarma))")
                    .transition(.opacity)
                    .onTapGesture {
                      withAnimation(.easeInOut(duration: 0.2)) {
                        if dataTypeFilter == "comments" {
                          dataTypeFilter = ""
                        } else {
                          dataTypeFilter = "comments"
                        }
                      }
                    }
                    .overlay(dataTypeFilter == "comments" ?
                             Color.accentColor.opacity(0.2)
                      .clipShape(RoundedRectangle(cornerRadius: 20))
                      .allowsHitTesting(false)
                             : nil)
                }
              }
              if let created = data.created {
                DataBlock(icon: "star.fill", label: "User since", value: "\(Date(timeIntervalSince1970: TimeInterval(created)).toFormat("MMM dd, yyyy"))")
                  .transition(.opacity)
              }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .transition(.opacity)
          }
          
          Text(dataTypeFilter.isEmpty ? "Latest activity" : "Latest " + dataTypeFilter)
            .fontSize(20, .bold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
          
          if let lastActivities = lastActivities {
            ForEach(Array(lastActivities.enumerated()), id: \.element) { i, item in
              let isComment: Bool = {
                switch item {
                case .second: // is comment
                  return true
                default:
                  return false
                }
              }()
                
              Group {
                MixedContentLink(content: item, theme: selectedTheme.postLinks)
                  .onAppear {
                    if i >= max(lastActivities.count - 7, 0) {
                      getNextData()
                    }
                  }
                  .allowsHitTesting(!isComment)
              }
              .contentShape(Rectangle())
              .onTapGesture {
                guard isComment else {
                  return
                }
                
                switch item {
                case .second(let comment):
                  if let data = comment.data, let link_id = data.link_id, let subID = data.subreddit {
                    navigateRedditDestination(.reddit(.postHighlighted(Post(id: link_id, subID: subID), comment.id)), model: redditNavigationModel, origin: redditNavigationOrigin)
                  }
                default:
                  return
                }
              }
              
              if selectedTheme.postLinks.divider.style != .no && i != (lastActivities.count - 1) {
                NiceDivider(divider: selectedTheme.postLinks.divider)
                  .id("user-view-\(i)-divider")
                  .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
              }
            }

            if lastActivities.isEmpty && !loadingOverview {
              Text("No activity found")
                .frame(maxWidth: .infinity, minHeight: 160)
                .opacity(0.35)
            }
          }
          
          if loadingOverview || loadingNextOverview {
            ProgressView()
              .progressViewStyle(.circular)
              .frame(maxWidth: .infinity, minHeight: 100 )
              .id("user-loading")
              .id(UUID()) // spawns unique spinner, swiftui bug.
          } else if reachedEndOfOverview && canPageOverview && lastActivities?.isEmpty == false {
            EndOfFeedView()
          }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .transition(.opacity)
      }
    }
    .loader(user.data == nil)
    .themedListBG(selectedTheme.lists.bg)
    .listStyle(.plain)
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

//struct UserView_Previews: PreviewProvider {
//    static var previews: some View {
//        UserView()
//    }
//}
