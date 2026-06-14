//
//  PressRoot.swift
//  winston
//
//  Design Lab · Press — editorial, the daily read.
//
//  Navigation system: a NavigationStack whose chrome relocates with width — a persistent
//  leading icon rail when wide (fold open / iPad), collapsing to a bottom glass pill when
//  narrow (fold closed / iPhone). Content is pushed, never split.
//

import SwiftUI

struct PressRoot: View {
  var onClose: () -> Void = {}

  enum PressRoute: Hashable { case post(String) }

  @State private var path: [PressRoute] = []
  @State private var selectedSubID: String? = nil   // nil = "The Daily"
  @Environment(\.horizontalSizeClass) private var hSize

  private var wide: Bool { hSize == .regular }
  private var feed: [MockPost] { MockData.posts(in: selectedSubID) }
  private var sectionTitle: String {
    guard let id = selectedSubID else { return "The Daily" }
    return MockData.subreddits.first { $0.id == id }?.displayName ?? "The Daily"
  }

  var body: some View {
    HStack(spacing: 0) {
      if wide {
        PressRail(selectedSubID: $selectedSubID)
        Rectangle().fill(PressPalette.rule).frame(width: 1).ignoresSafeArea()
      }

      NavigationStack(path: $path) {
        PressFeed(posts: feed, sectionTitle: sectionTitle) { post in
          path.append(.post(post.id))
        }
        .navigationDestination(for: PressRoute.self) { route in
          switch route {
          case .post(let id):
            if let post = MockData.feed.first(where: { $0.id == id }) {
              PressPostDetail(post: post)
            }
          }
        }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            if !wide {
              Text("Press")
                .font(.system(.headline, design: .serif).weight(.black))
                .foregroundStyle(PressPalette.accent)
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: onClose) {
              Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
            }
            .tint(PressPalette.ink)
          }
        }
        .toolbarBackground(PressPalette.paper, for: .navigationBar)
      }
      .safeAreaInset(edge: .bottom) {
        if !wide {
          PressBottomBar(selectedSubID: $selectedSubID)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
      }
    }
    .background(PressPalette.paper.ignoresSafeArea())
    .tint(PressPalette.ink)
    .preferredColorScheme(.light)
    .designLabImageSession()
    .onChange(of: selectedSubID) { _, _ in
      withAnimation(.snappy) { path.removeAll() }
    }
  }
}

#Preview("Press") {
  PressRoot()
}
