//
//  InboxNotification.swift
//  winston
//
//  Created by Igor Marcossi on 10/07/23.
//

import SwiftUI
import Defaults

struct InboxNotificationLink: View {
  @State private var pressed = false
  @Environment(\.openURL) private var openURL
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  
  let notification: InboxNotification
  let markRead: () async -> Void
  
  var body: some View {
    InboxNotificationRow(notification: notification)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .themedListRowLikeBG()
      .mask(RR(20, .black))
      .compositingGroup()
      .opacity(notification.isUnread ? 1 : 0.65)
      .swipyActions(pressing: $pressed, onTap: {
        Task(priority: .background) {
          await markRead()
        }
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
      }, rightActionIcon: notification.isUnread ? "eye.fill" : "eye.slash.fill", rightActionHandler: {
        Task(priority: .background) {
          await markRead()
        }
      })
  }
}

private struct InboxNotificationRow: View {
  let notification: InboxNotification
  
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      InboxNotificationAvatar(notification: notification)
      
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(notification.title)
            .fontSize(16, .semibold)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          if notification.isUnread {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 8, height: 8)
          }
        }
        
        if let body = notification.body, !body.isEmpty {
          Text(body.md())
            .lineLimit(3)
            .fontSize(15)
            .opacity(0.75)
        }
        
        HStack(spacing: 8) {
          Label {
            Text(notification.displaySource ?? "Reddit")
              .lineLimit(1)
          } icon: {
            Image(systemName: notification.kindIcon)
          }
          if let sentAt = notification.sentAt {
            Text(timeSince(Int(sentAt.timeIntervalSince1970)))
          }
        }
        .fontSize(12, .medium)
        .opacity(0.55)
      }
    }
  }
}

private struct InboxNotificationAvatar: View {
  let notification: InboxNotification
  
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Avatar(
        url: notification.avatarURL,
        userID: notification.authorName ?? notification.messageType ?? "reddit",
        avatarSize: 42
      )
      Image(systemName: notification.kindIcon)
        .fontSize(11, .bold)
        .foregroundColor(.white)
        .frame(width: 18, height: 18)
        .background(Circle().fill(notification.kindColor))
        .offset(x: 3, y: 3)
    }
    .frame(width: 48, height: 48, alignment: .topLeading)
  }
}

private extension InboxNotification {
  var kindIcon: String {
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
  
  var kindColor: Color {
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

//struct InboxNotification_Previews: PreviewProvider {
//    static var previews: some View {
//        InboxNotification()
//    }
//}
