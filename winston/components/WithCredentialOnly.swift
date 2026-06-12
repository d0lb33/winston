//
//  WithAccountOnly.swift
//  winston
//
//  Gates a tab behind having a connected Reddit account (GraphQL session).
//

import SwiftUI

struct WithAccountOnly<Content: View>: View {
  @ObservedObject private var wire = RedditWire.shared
  @ViewBuilder let content: () -> Content
    var body: some View {
      if !wire.connected {
        VStack(spacing: 20) {
          VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
              .fontSize(64, .bold)
              .opacity(0.5)
            VStack(spacing: 4) {
              Text("No account connected")
                .fontSize(24, .bold)
                .opacity(0.5)
              Text("We can't load this page 😔").fontSize(16, .medium).opacity(0.35)
            }
          }
          Button("Log in to Reddit", systemImage: "person.fill.badge.plus") {
            Nav.present(.onboarding)
          }
          .buttonStyle(.actionOutlined)
          .opacity(0.5)
        }
        .compositingGroup()
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        content()
      }
    }
}
