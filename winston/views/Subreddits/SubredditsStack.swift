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
  @ObservedObject var router: Router
  @ObservedObject private var wire = RedditWire.shared
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      AuroraRoot(router: router, accountID: wire.accountScopeID)
        .environment(\.contentWidth, max(Double(proxy.size.width), 1))
        .onAppear {
          ScreenMetrics.refresh(size: proxy.size, scale: displayScale)
        }
        .onGeometryChange(for: CGSize.self) { geometry in
          geometry.size
        } action: { newSize in
          ScreenMetrics.refresh(size: newSize, scale: displayScale)
        }
    }
  }
}
