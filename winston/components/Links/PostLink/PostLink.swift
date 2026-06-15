//
//  Post.swift
//  winston
//
//  Created by Igor Marcossi on 28/06/23.
//

import SwiftUI
import Defaults
import NukeUI



let POSTLINK_INNER_H_PAD: CGFloat = 16

struct PostLink: View, Equatable, Identifiable {
  static func == (lhs: PostLink, rhs: PostLink) -> Bool {
    return lhs.id == rhs.id && lhs.repostAvatarRequest?.url == rhs.repostAvatarRequest?.url && lhs.theme == rhs.theme && lhs.defSettings == rhs.defSettings && lhs.compactPerSubreddit == rhs.compactPerSubreddit && lhs.postStyleOverride == rhs.postStyleOverride && lhs.useNative == rhs.useNative
  }
  
  //  var disableOuterVSpacing = false
  var id: String
  weak var controller: UIViewController? = nil
  var repostAvatarRequest: ImageRequest?
  var theme: SubPostsListTheme
  var showSub = false
  var secondary = false
  let compactPerSubreddit: Bool?
  let postStyleOverride: PostLinkDisplayStyle?
  let contentWidth: CGFloat
  var defSettings: PostLinkDefSettings = Defaults[.PostLinkDefSettings]
  /// When this PostLink is an embedded crosspost, the inline video's feed-gating key is
  /// forced to the OUTER post id (the one the feed actually tracks for center election),
  /// so the embedded player autoplays with the rest of the feed instead of never matching.
  var inlineVideoKeyOverride: String? = nil
  /// When true, render the iOS-27 native feed rows (PostLinkNative / PostLinkNativeCompact)
  /// instead of the legacy variants. Threaded down as a plain Bool so PostLink never has to
  /// JSON-decode PostPageDefSettings in its per-row body.
  var useNative: Bool = false

  init(id: String, controller: UIViewController? = nil, repostAvatarRequest: ImageRequest? = nil, theme: SubPostsListTheme, showSub: Bool = false, secondary: Bool = false, compactPerSubreddit: Bool?, postStyleOverride: PostLinkDisplayStyle? = nil, contentWidth: CGFloat, defSettings: PostLinkDefSettings = Defaults[.PostLinkDefSettings], inlineVideoKeyOverride: String? = nil, useNative: Bool = false) {
    self.id = id
    self.controller = controller
    self.repostAvatarRequest = repostAvatarRequest
    self.theme = theme
    self.showSub = showSub
    self.secondary = secondary
    self.compactPerSubreddit = compactPerSubreddit
    self.postStyleOverride = postStyleOverride
    self.contentWidth = contentWidth
    self.defSettings = defSettings
    self.inlineVideoKeyOverride = inlineVideoKeyOverride
    self.useNative = useNative
  }

  var body: some View {
    ScrollPerfProbe.shared.bump("cellBody")
    let style = defSettings.resolvedPostStyle(styleOverride: postStyleOverride, compactOverride: compactPerSubreddit)
    return Group {
      if useNative {
        switch style {
        case .compact:
          PostLinkNativeCompact(
            id: id,
            controller: controller,
            theme: theme,
            showSub: showSub,
            secondary: secondary,
            contentWidth: contentWidth,
            defSettings: defSettings
          )
          .equatable()
        default:
          // .clean and .classic both collapse to the native "normal" row.
          PostLinkNative(
            id: id,
            controller: controller,
            theme: theme,
            showSub: showSub,
            secondary: secondary,
            contentWidth: contentWidth,
            defSettings: defSettings,
            inlineVideoKeyOverride: inlineVideoKeyOverride
          )
          .equatable()
        }
      } else {
      switch style {
      case .compact:
        PostLinkCompact(
          id: id,
          controller: controller,
          theme: theme,
          showSub: showSub,
          secondary: secondary,
          contentWidth: contentWidth,
          defSettings: defSettings
        )
        .equatable()
      case .classic:
        PostLinkNormal(
          id: id,
          controller: controller,
          theme: theme,
          showSub: showSub,
          secondary: secondary,
          contentWidth: contentWidth,
          defSettings: defSettings,
          inlineVideoKeyOverride: inlineVideoKeyOverride
        )
        .equatable()
      case .clean:
        PostLinkClean(
          id: id,
          controller: controller,
          theme: theme,
          showSub: showSub,
          secondary: secondary,
          contentWidth: contentWidth,
          defSettings: defSettings,
          inlineVideoKeyOverride: inlineVideoKeyOverride
        )
        .equatable()
      }
      }
    }
  }
}

extension View {
  func postLinkStyle(showSubBottom: Bool = false, post: Post, sub: Subreddit, theme: SubPostsListTheme, size: CGSize, secondary: Bool, openPost: @escaping () -> (), readPostOnScroll: Bool, innerPadding: EdgeInsets? = nil) -> some View {
    let seen = (post.data?.winstonSeen ?? false)
    let padding = innerPadding ?? EdgeInsets(top: theme.theme.innerPadding.vertical, leading: theme.theme.innerPadding.horizontal, bottom: theme.theme.innerPadding.vertical, trailing: theme.theme.innerPadding.horizontal)
    return self
      .padding(padding)
      .background(PostLinkBG(theme: theme, stickied: post.data?.stickied, secondary: secondary).equatable())
      .overlay(PostLinkGlowDot(unseenType: theme.theme.unseenType, seen: seen, badge: false).equatable(), alignment: .topTrailing)
      .contentShape(Rectangle())
      .compositingGroup()
//      .brightness(isOpen.wrappedValue ? 0.075 : 0)
      .contextMenu(menuItems: { PostLinkContext(post: post) }, preview: { PostLinkContextPreview(post: post, sub: sub) })
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .onDisappear {
        if readPostOnScroll {
          FeedScrollWorkCoordinator.shared.markSeenWhenIdle(post)
        }
      }
  }

  func postReadDimmed(post: Post, theme: SubPostsListTheme) -> some View {
    let seen = post.data?.winstonSeen ?? false
    let fadeReadPosts = theme.theme.unseenType == .fade
    let readOpacity = fadeReadPosts ? theme.theme.unseenFadeOpacity : 0.68
    return self
      .saturation(seen ? 0.45 : 1)
      .opacity(seen ? readOpacity : 1)
  }
}


struct PostLinkGlowDot: View, Equatable {
  static func == (lhs: PostLinkGlowDot, rhs: PostLinkGlowDot) -> Bool {
    return lhs.unseenType == rhs.unseenType && lhs.seen == rhs.seen
  }
  let unseenType: UnseenType
  let seen: Bool
  let badge: Bool
  
  var body: some View {
    ZStack {
      switch unseenType {
      case .dot(let color):
        ZStack {
          Circle()
            .fill(badge ? color() : Color.hex("CFFFDE"))
            .frame(width: 5, height: 5)
          Circle()
            .fill(color())
            .frame(width: 8, height: 8)
            .blur(radius: 8)
        }
      case .fade:
        EmptyView()
      }
    }
    .padding(badge ? .horizontal : .all, badge ? 6 : 11)
    .scaleEffect(seen ? 0.1 : 1)
    .opacity(seen ? 0 : 1)
    .allowsHitTesting(false)
  }
}

struct PostLinkBG: View, Equatable {
  static func == (lhs: PostLinkBG, rhs: PostLinkBG) -> Bool {
    return lhs.theme == rhs.theme && lhs.stickied == rhs.stickied && lhs.secondary == rhs.secondary
  }
  
  let theme: SubPostsListTheme
  let stickied: Bool?
  let secondary: Bool
  var body: some View {
    ZStack {
      if !secondary && theme.theme.outerHPadding == 0 {
        theme.theme.bg.color()
        if stickied ?? false {
          theme.theme.stickyPostBorderColor.color()
        }
      } else {
        LiquidGlassCardBackground(
          cornerRadius: theme.theme.cornerRadius,
          fillColor: secondary ? .primary.opacity(0.06) : theme.theme.bg.color(),
          strokeColor: (stickied ?? false) ? theme.theme.stickyPostBorderColor.color() : nil,
          strokeWidth: (stickied ?? false) ? theme.theme.stickyPostBorderColor.thickness : 0
        )
      }
    }
    .allowsHitTesting(false)
    .mask(RR(theme.theme.cornerRadius, Color.black).equatable())
  }
}

struct LiquidGlassCardBackground: View {
  let cornerRadius: CGFloat
  let fillColor: Color
  var strokeColor: Color? = nil
  var strokeWidth: CGFloat = 0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      // Static translucent fill instead of a live glass/material backdrop blur.
      // The blur (.glassEffect / .ultraThinMaterial) was the dominant per-frame GPU
      // cost while scrolling a card feed; a flat fill blends for free.
      shape
        .fill(fillColor.opacity(0.85))

      shape
        .stroke(.white.opacity(0.18), lineWidth: 0.7)

      shape
        .stroke(.primary.opacity(0.06), lineWidth: 0.5)

      if let strokeColor, strokeWidth > 0 {
        shape
          .stroke(strokeColor, lineWidth: strokeWidth)
      }
    }
  }
}
