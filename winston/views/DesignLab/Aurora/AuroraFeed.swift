//
//  AuroraFeed.swift
//  winston
//
//  Design Lab · Aurora family — the middle (content) column.
//  A selection-driven List: in compact width the NavigationSplitView collapses to a
//  stack and selecting a card pushes the detail; in regular width the same selection
//  populates the third (detail) pane. One code path, two behaviours.
//

import SwiftUI

enum AuroraSort: String, CaseIterable {
  case hot, new, top
  var label: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .hot: "flame.fill"
    case .new: "clock.fill"
    case .top: "arrow.up.circle.fill"
    }
  }
}

struct AuroraFeed: View {
  let posts: [MockPost]
  let title: String
  let community: MockSubreddit?
  @Binding var selectedPostID: String?
  @Binding var sort: AuroraSort
  @Environment(\.horizontalSizeClass) private var hSize

  var body: some View {
    List(selection: $selectedPostID) {
      if let community {
        AuroraCommunityHeader(sub: community)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 2, trailing: 14))
      }
      ForEach(posts) { post in
        AuroraCard(post: post, isSelected: post.id == selectedPostID && hSize == .regular)
          .tag(post.id)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      AuroraSortBar(sort: $sort)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
  }
}

struct AuroraSortBar: View {
  @Binding var sort: AuroraSort
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack {
      Spacer()
      HStack(spacing: 4) {
        ForEach(AuroraSort.allCases, id: \.self) { s in
          Button {
            withAnimation(.snappy) { sort = s }
          } label: {
            Label(s.label, systemImage: s.symbol)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 13).padding(.vertical, 8)
              .foregroundStyle(sort == s ? (theme.isDark ? Color.black : Color.white) : Color.primary)
              .background { if sort == s { Capsule().fill(theme.accent) } }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(5)
      .glassEffect(.regular.interactive(), in: .capsule)
      Spacer()
    }
  }
}
