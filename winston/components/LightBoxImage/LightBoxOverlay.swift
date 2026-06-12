//
//  LightBoxOverlay.swift
//  winston
//
//  Created by Igor Marcossi on 07/08/23.
//

import SwiftUI
import Defaults
import NukeUI

struct LightBoxOverlay: View {
  let postTitle: String
  let badgeKit: BadgeKit
  let avatarImageRequest: ImageRequest?
  var opacity: CGFloat
  var imagesArr: [ImgExtracted]
  var activeIndex: Int
  @Binding var loading: Bool
  @Environment(\.dismiss) var dismiss
  @Binding var done: Bool
  @Environment(\.useTheme) private var selectedTheme
  @State private var isPresentingShareSheet = false
  @State private var sharedImageData: Data?

  private var safeActiveIndex: Int? {
    guard !imagesArr.isEmpty else { return nil }
    return min(max(activeIndex, 0), imagesArr.count - 1)
  }

  var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 8) {
          Text(postTitle)
            .fontSize(20, .semibold)
            .allowsHitTesting(false)
          BadgeView(avatarRequest: avatarImageRequest, saved: false, usernameColor: nil, author: badgeKit.author, fullname: badgeKit.authorFullname, userFlair: badgeKit.userFlair, created: badgeKit.created, avatarURL: nil, theme: selectedTheme.postLinks.theme.badge)
        }

        Spacer(minLength: 12)

        LightBoxButton(icon: "xmark", accessibilityLabel: "Close media viewer") {
          dismiss()
        }
      }
      
      Spacer()
      
      if imagesArr.count > 1 {
        Text("\((safeActiveIndex ?? 0) + 1)/\(imagesArr.count)")
          .fontSize(16, .semibold)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Capsule(style: .continuous).fill(.regularMaterial))
          .frame(maxWidth: .infinity)
          .allowsHitTesting(false)
      }
      
      HStack(spacing: 12) {
        
          // MANDRAKE
//           if let post {
//               LightBoxButton(icon: "bubble.right") {
//             if let data = post.data {
//                   Nav.to(.reddit(.post(Post(id: post.id, subID: data.subreddit))))
//                   dismiss()
//                 }
//               }
//           }
        
        
        LightBoxButton(icon: "square.and.arrow.down", accessibilityLabel: "Save image") {
          guard let safeActiveIndex else { return }
          withAnimation(spring) {
            loading = true
          }
          saveMedia(imagesArr[safeActiveIndex].url.absoluteString, .image) { result in
            withAnimation(spring) {
              loading = false
              done = result
            }
          }
        }
        LightBoxButton(icon: "square.and.arrow.up", accessibilityLabel: "Share image"){
          guard let safeActiveIndex else { return }
          withAnimation(spring) {
            loading = true
          }
          Task {
            do {
              let data = try await downloadAndSaveImage(url: imagesArr[safeActiveIndex].url)
              await MainActor.run {
                sharedImageData = data
                loading = false
                isPresentingShareSheet = true
              }
            } catch {
              AppDiagnostics.asyncRecord(
                .warning,
                category: "ui.image",
                message: "Image share download failed",
                metadata: [
                  "url": imagesArr[safeActiveIndex].url.absoluteString,
                  "error": error.localizedDescription
                ]
              )
              await MainActor.run {
                loading = false
              }
            }
          }
        }
        .contentShape(Circle())
        .sheet(isPresented: $isPresentingShareSheet) {
          if let sharedImageData = sharedImageData, let uiimg = UIImage(data: sharedImageData){
            let image = ShareImage(placeholderItem: uiimg)
            ShareSheet(items: [image])
          }
        }
      }
      .compositingGroup()
      .frame(maxWidth: .infinity)
    }
    .multilineTextAlignment(.leading)
    .foregroundColor(.white)
    .padding(.horizontal, 12)
    .padding(.bottom, 32)
    .padding(.top, 64)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      VStack(spacing: 0) {
        Rectangle()
          .fill(LinearGradient(
            gradient: Gradient(stops: [
              .init(color: Color.black.opacity(1), location: 0),
              .init(color: Color.black.opacity(0), location: 1)
            ]),
            startPoint: .top,
            endPoint: .bottom
          ))
          .frame(height: 150)
        Spacer()
        Rectangle()
          .fill(LinearGradient(
            gradient: Gradient(stops: [
              .init(color: Color.black.opacity(1), location: 0),
              .init(color: Color.black.opacity(0), location: 1)
            ]),
            startPoint: .bottom,
            endPoint: .top
          ))
          .frame(height: 150)
      }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    )
    .compositingGroup()
    .opacity(opacity)
    .allowsHitTesting(opacity != 0)
  }
}
