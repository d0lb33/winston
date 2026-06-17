//
//  Inbox.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI
import Defaults

struct Inbox: View {
  /// Single source of truth for this single-stack surface.
  let nav: StackNav

  @State private var notifications: [InboxNotification] = []
  @State private var nextAfter: String?
  @State private var reachedEnd = false
  @State private var loading = false
  @State private var loadingMore = false
  @Default(.GeneralDefSettings) private var generalDefSettings
  
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
    @Bindable var nav = nav

    NavigationStack(path: $nav.path) {
      InboxList(
        notifications: notifications,
        loadingMore: loadingMore,
        reachedEnd: reachedEnd,
        fetchMore: { await fetch(true) },
        markRead: { await markRead($0) }
      )
      .auroraListChrome()
      .redditNavigation(nav, origin: .content)
      .redditDestinations(nav, origin: .content)
      .loader(loading)
      .onAppear {
        Task(priority: .background) {
          await fetch()
        }
      }
      .refreshable {
        await fetch(false, true)
      }
      .onChange(of: generalDefSettings.redditCredentialSelectedID) {
        notifications = []
        nextAfter = nil
        reachedEnd = false
        Task(priority: .background) { await fetch(false, true) }
      }
      .navigationTitle("Inbox")
    }
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
            AuroraInboxNotificationRow(notification: notification) {
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
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray")
        .font(.system(size: 42, weight: .semibold))
        .foregroundStyle(theme.accent)
      Text("No inbox notifications")
        .font(.headline.weight(.semibold))
      Text("Replies, mentions, chat updates, and Reddit activity notifications will appear here.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct AuroraInboxNotificationRow: View {
  let notification: InboxNotification
  let markRead: () async -> Void

  @Environment(\.openURL) private var openURL
  @Environment(\.auroraTheme) private var theme
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  var body: some View {
    Button {
      Task(priority: .background) {
        await markRead()
      }
      openNotification()
    } label: {
      HStack(alignment: .top, spacing: 12) {
        avatar
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous)
          .stroke(notification.isUnread ? theme.accent.opacity(0.55) : theme.hairline, lineWidth: notification.isUnread ? 1.1 : 0.7)
      )
      .opacity(notification.isUnread ? 1 : 0.68)
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        Task(priority: .background) {
          await markRead()
        }
      } label: {
        Label(notification.isUnread ? "Mark Read" : "Read", systemImage: notification.isUnread ? "eye.fill" : "eye")
      }
      .tint(theme.accent)
    }
  }

  private var avatar: some View {
    ZStack(alignment: .bottomTrailing) {
      Avatar(
        url: notification.avatarURL,
        userID: notification.authorName ?? notification.messageType ?? "reddit",
        avatarSize: 42
      )
      Image(systemName: notification.auroraKindIcon)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(Circle().fill(notification.auroraKindColor))
        .offset(x: 3, y: 3)
    }
    .frame(width: 48, height: 48, alignment: .topLeading)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(notification.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        if notification.isUnread {
          Circle()
            .fill(theme.accent)
            .frame(width: 8, height: 8)
        }
      }

      if let body = notification.body, !body.isEmpty {
        Text(body.md())
          .lineLimit(3)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Label(notification.displaySource ?? "Reddit", systemImage: notification.auroraKindIcon)
          .lineLimit(1)
        if let sentAt = notification.sentAt {
          Text(timeSince(Int(sentAt.timeIntervalSince1970)))
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.tertiary)
    }
  }

  private func openNotification() {
    if let postID = notification.postBareID {
      let post = notification.subredditName.map { Post(id: postID, subID: $0) } ?? Post(id: postID)
      if let highlightID = notification.commentFullname {
        navigateRedditDestination(.reddit(.postHighlighted(post, highlightID)), model: redditNavigationModel, origin: redditNavigationOrigin)
      } else {
        navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
      }
    } else if let urlString = notification.deeplinkURL, let url = URL(string: urlString) {
      openURL(url)
    }
  }
}

private extension InboxNotification {
  var auroraKindIcon: String {
    switch messageType {
    case "POST_REPLY":
      return "message.circle.fill"
    case "COMMENT_REPLY", "USERNAME_MENTION":
      return "arrowshape.turn.up.left.circle.fill"
    case "CHAT_ACCEPT_INVITE":
      return "bubble.left.and.bubble.right.fill"
    case "GAMIFICATION_ACHIEVEMENT_UNLOCKED":
      return "trophy.fill"
    case "GAMIFICATION_REMINDER":
      return "flame.fill"
    case "POST_MATCH":
      return "person.3.fill"
    default:
      return postID == nil ? "bell.fill" : "message.circle.fill"
    }
  }

  var auroraKindColor: Color {
    switch messageType {
    case "POST_REPLY":
      return .accentColor
    case "COMMENT_REPLY", "USERNAME_MENTION":
      return .green
    case "CHAT_ACCEPT_INVITE":
      return .blue
    case "GAMIFICATION_ACHIEVEMENT_UNLOCKED", "GAMIFICATION_REMINDER":
      return .orange
    default:
      return .secondary
    }
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
