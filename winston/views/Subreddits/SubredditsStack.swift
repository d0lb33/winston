//
//  SubredditsStack.swift
//  winston
//
//  Created by Igor Marcossi on 19/09/23.
//
//  The Posts tab root. Now a thin host for the Aurora 3-pane shell (communities
//  sidebar | feed | post+comments), wired to this tab's Router for deep navigation.
//

import SwiftUI

struct SubredditsStack: View {
  let nav: PostsNav
  @ObservedObject private var wire = RedditWire.shared
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let metrics = SubredditsViewportMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)

      AuroraRoot(nav: nav, accountID: wire.accountScopeID)
        .environment(\.contentWidth, max(Double(proxy.size.width), 1))
        .onAppear {
          ScreenMetrics.refresh(size: metrics.fullSize, scale: displayScale, safeAreaInsets: metrics.uiEdgeInsets)
        }
        .onGeometryChange(for: SubredditsViewportMetrics.self) { geometry in
          SubredditsViewportMetrics(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
        } action: { newMetrics in
          ScreenMetrics.refresh(size: newMetrics.fullSize, scale: displayScale, safeAreaInsets: newMetrics.uiEdgeInsets)
        }
    }
  }
}

private struct SubredditsViewportMetrics: Equatable {
  let size: CGSize
  let top: CGFloat
  let leading: CGFloat
  let bottom: CGFloat
  let trailing: CGFloat

  init(size: CGSize, safeAreaInsets: EdgeInsets) {
    self.size = size
    self.top = safeAreaInsets.top
    self.leading = safeAreaInsets.leading
    self.bottom = safeAreaInsets.bottom
    self.trailing = safeAreaInsets.trailing
  }

  var fullSize: CGSize {
    CGSize(width: size.width + leading + trailing, height: size.height + top + bottom)
  }

  var uiEdgeInsets: UIEdgeInsets {
    UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
  }
}
