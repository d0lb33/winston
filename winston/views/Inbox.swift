//
//  Inbox.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import Defaults

struct Inbox: View {
  @ObservedObject var router: Router
  
  @State private var notifications: [InboxNotification] = []
  @State private var nextAfter: String?
  @State private var reachedEnd = false
  @State private var loading = false
  @State private var loadingMore = false
  @Default(.GeneralDefSettings) private var generalDefSettings
  @Environment(\.useTheme) private var selectedTheme
  
  func fetch(_ loadMore: Bool = false, _ force: Bool = false) async {
    if loading || loadingMore { return }
    if !loadMore && !notifications.isEmpty && !force { return }
    if loadMore && reachedEnd { return }
    await MainActor.run {
      withAnimation {
        if loadMore {
          loadingMore = true
        } else {
          loading = true
        }
      }
    }
    let after = loadMore ? nextAfter : nil
    let (newItems, cursor) = await RedditWire.shared.inboxNotifications(after: after)
    await MainActor.run {
      withAnimation {
        loading = false
        loadingMore = false
        nextAfter = cursor
        reachedEnd = cursor == nil
        if !newItems.isEmpty {
          if loadMore {
            let seen = Set(notifications.map(\.id))
            notifications.append(contentsOf: newItems.filter { !seen.contains($0.id) })
          } else {
            notifications = newItems
          }
        } else if !loadMore {
          notifications = []
        }
      }
    }
  }
  
  func markRead(_ notification: InboxNotification) async {
    guard notification.isUnread, let sentAt = notification.sentAtRaw else { return }
    let didMark = await RedditWire.shared.markInboxSeen(lastSentAt: sentAt)
    guard didMark else { return }
    await MainActor.run {
      withAnimation {
        notifications = notifications.map { item in
          guard item.id == notification.id else { return item }
          return InboxNotification(
            id: item.id,
            title: item.title,
            body: item.body,
            authorName: item.authorName,
            subredditName: item.subredditName,
            avatarURL: item.avatarURL,
            deeplinkURL: item.deeplinkURL,
            sentAt: item.sentAt,
            sentAtRaw: item.sentAtRaw,
            readAt: sentAt,
            messageType: item.messageType,
            contextType: item.contextType,
            postID: item.postID,
            commentID: item.commentID,
            parentCommentID: item.parentCommentID,
            postTitle: item.postTitle
          )
        }
      }
    }
  }
  
  var body: some View {
    NavigationStack(path: $router.fullPath) {
      InboxList(
        notifications: notifications,
        loadingMore: loadingMore,
        reachedEnd: reachedEnd,
        fetchMore: { await fetch(true) },
        markRead: { await markRead($0) }
      )
      .themedListBG(selectedTheme.lists.bg)
      .scrollContentBackground(.hidden)
      .injectInTabDestinations(viewControllerHolder: router.navController)
      .loader(loading)
      .onAppear {
        Task(priority: .background) {
          await fetch()
        }
      }
      .refreshable {
        await fetch(false, true)
      }
      .onChange(of: generalDefSettings.redditCredentialSelectedID) { _ in
        notifications = []
        nextAfter = nil
        reachedEnd = false
        Task(priority: .background) { await fetch(false, true) }
      }
      .navigationTitle("Inbox")
    }
//    .swipeAnywhere()
  }
}

private struct InboxList: View {
  let notifications: [InboxNotification]
  let loadingMore: Bool
  let reachedEnd: Bool
  let fetchMore: () async -> Void
  let markRead: (InboxNotification) async -> Void
  
  var body: some View {
    Group {
      if notifications.isEmpty {
        InboxEmptyState()
      } else {
        List {
          ForEach(notifications) { notification in
            InboxNotificationLink(notification: notification) {
              await markRead(notification)
            }
          }
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
          
          if !reachedEnd {
            InboxLoadMoreRow(loadingMore: loadingMore)
              .onAppear {
                Task(priority: .background) {
                  await fetchMore()
                }
              }
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
          }
        }
      }
    }
  }
}

private struct InboxEmptyState: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray")
        .fontSize(42, .semibold)
        .opacity(0.45)
      Text("No inbox notifications")
        .fontSize(18, .semibold)
      Text("Replies, mentions, chat updates, and Reddit activity notifications will appear here.")
        .fontSize(14)
        .multilineTextAlignment(.center)
        .opacity(0.6)
        .padding(.horizontal, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct InboxLoadMoreRow: View {
  let loadingMore: Bool
  
  var body: some View {
    HStack {
      Spacer()
      if loadingMore {
        ProgressView()
      }
      Spacer()
    }
    .padding(.vertical, 18)
  }
}


//struct Inbox_Previews: PreviewProvider {
//    static var previews: some View {
//        Inbox()
//    }
//}
