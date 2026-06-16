//
//  PostsInBoxView.swift
//  winston
//
//  Created by Igor Marcossi on 05/08/23.
//

import SwiftUI
import Defaults

struct PostsInBoxView: View {
  @Binding var initialSelected: NavDest?
  @Default(.postsInBox) private var postsInBox
  
  var body: some View {
      if postsInBox.count > 0 {
        Section("Posts Box") {
          ScrollView(.horizontal) {
            HStack(spacing: 12) {
              ForEach(postsInBox, id: \.self.id) { post in
                AuroraPinnedPostCard(initialSelected: $initialSelected, postInBox: post)
                  .animation(spring, value: postsInBox)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
          }
          .id("quickPosts")
          .onAppear { Task(priority: .background) { await updatePostsInBox() } }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
      }
  }
}

private struct AuroraPinnedPostCard: View {
  @Binding var initialSelected: NavDest?
  @Default(.postsInBox) private var postsInBox
  @Environment(\.contentWidth) private var contentWidth
  @Environment(\.auroraTheme) private var theme
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  let postInBox: PostInBox
  @StateObject private var post: Post
  @State private var dragging = false
  @State private var deleting = false
  @State private var offsetY: CGFloat?

  init(initialSelected: Binding<NavDest?>, postInBox: PostInBox) {
    self._initialSelected = initialSelected
    self.postInBox = postInBox
    self._post = StateObject(wrappedValue: Post(id: postInBox.id, subID: postInBox.subredditName))
  }

  private var cardWidth: CGFloat {
    min(max(contentWidth / 1.75, 180), max(contentWidth, 1))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        AuroraSubIcon(name: postInBox.subredditName, size: 22)
        Text("r/\(postInBox.subredditName)")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        Image(systemName: "shippingbox.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.accent)
      }

      Text(postInBox.title.escape)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      HStack(spacing: 10) {
        Label(formatBigNumber(postInBox.commentsCount ?? 0), systemImage: "bubble.left.fill")
        if let newComments = postInBox.newCommentsCount, newComments > 0 {
          Text("+\(newComments)")
            .foregroundStyle(theme.accent)
        }
        if let createdAt = postInBox.createdAt {
          Label(timeSince(Int(createdAt)), systemImage: "clock")
        }
        Spacer(minLength: 0)
        Label(formatBigNumber(postInBox.score ?? 0), systemImage: "arrow.up")
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(width: cardWidth, height: 124, alignment: .topLeading)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous)
        .stroke(theme.hairline, lineWidth: 0.7)
    )
    .offset(y: offsetY ?? 0)
    .scaleEffect(dragging ? 0.975 : 1)
    .background(discardBackground)
    .contentShape(Rectangle())
    .onTapGesture(perform: openPost)
    .gesture(removeGesture)
  }

  @ViewBuilder private var background: some View {
    if let image = postInBox.img, let url = URL(string: image), !image.isEmpty {
      URLImage(url: url)
        .scaledToFill()
        .opacity(0.16)
        .frame(width: cardWidth, height: 124)
        .clipped()
        .overlay(theme.cardFill.opacity(0.88))
    } else {
      theme.cardFill
    }
  }

  private var discardBackground: some View {
    Text("DISCARD")
      .font(.caption.weight(.bold))
      .foregroundStyle(.red)
      .frame(width: cardWidth, height: abs(offsetY ?? 0))
      .saturation(deleting ? 1 : 0)
      .scaleEffect(deleting ? 1 : 0.85)
  }

  private var removeGesture: some Gesture {
    LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
      .onEnded { _ in
        withAnimation(spring) { dragging = true }
        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.prepare()
        impact.impactOccurred()
      }
      .sequenced(before: DragGesture())
      .onChanged { sequence in
        guard case .second(_, let dragValue?) = sequence else { return }
        var transaction = Transaction()
        transaction.isContinuous = true
        transaction.animation = draggingAnimation
        withTransaction(transaction) {
          offsetY = dragValue.translation.height
        }
        let shouldDelete = abs(dragValue.translation.height) > 70
        if shouldDelete != deleting {
          withAnimation(spring) { deleting = shouldDelete }
          let impact = UIImpactFeedbackGenerator(style: .rigid)
          impact.prepare()
          impact.impactOccurred()
        }
      }
      .onEnded { sequence in
        guard case .second(_, let dragValue?) = sequence else {
          withAnimation(spring) {
            dragging = false
            deleting = false
            offsetY = nil
          }
          return
        }

        let translation = dragValue.translation.height
        let predicted = dragValue.predictedEndTranslation.height
        let remove = abs(translation) > 70 || abs(predicted) > 300
        withAnimation(spring) {
          dragging = false
          deleting = false
          offsetY = remove ? (predicted >= 0 ? 300 : -300) : nil
          if remove {
            postsInBox = postsInBox.filter { $0.id != postInBox.id }
          }
        }
      }
  }

  private func openPost() {
    let destination = NavDest.reddit(.post(post))
    if let redditNavigationModel {
      navigateRedditDestination(destination, model: redditNavigationModel, origin: redditNavigationOrigin)
    } else {
      initialSelected = destination
    }
  }
}
