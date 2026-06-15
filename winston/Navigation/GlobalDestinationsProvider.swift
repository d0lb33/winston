//
//  injectGlobalDestinations.swift
//  winston
//
//  Created by Igor Marcossi on 09/12/23.
//

import SwiftUI
import Defaults

struct GlobalDestinationsProvider<C: View>: View {
  @ObservedObject private var nav = Nav.shared
  
  @Environment(\.tabBarHeight) private var tabBarHeight

  @ViewBuilder var content: () -> C
  var body: some View {
    content()
      .replyModalPresenter()
      .sheet(item: $nav.presentingSheet) { data in
        GeometryReader { geo in
          Group {
            switch data {
            case .announcement(let announcement): AnnouncementSheet(announcement: announcement)
            case .tipJar: TipJar()
            case .onboarding: OnboardingGraphQL()
            }
          }
          .environment(\.tabBarHeight, tabBarHeight)
          .environment(\.sheetHeight, geo.size.height)
        }
        .coordinateSpace(name: "sheet")
        .environment(\.brighterBG, true)
      }
  }
}
