//
//  AuroraRoot.swift
//  winston
//
//  Design Lab · Aurora family — the shared experience, parameterised by AuroraTheme.
//
//  Navigation system: NavigationSplitView (sidebar | feed | post+comments).
//  Resize behaviour: collapses to a single stack on compact width (fold closed),
//  expands to 2–3 panes when wide (fold open / iPad / Stage Manager). The same
//  value-based selections drive both layouts. Midnight / Dawn / Eclipse are the same
//  views with a different theme injected through the environment.
//

import SwiftUI

struct AuroraRoot: View {
  var theme: AuroraTheme = .midnight
  var displayName: String = "Aurora"
  var onClose: () -> Void = {}

  static let popularID = "__popular__"

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var selectedSubID: String? = AuroraRoot.popularID
  @State private var selectedPostID: String? = nil
  @State private var sort: AuroraSort = .hot

  private var subFilter: String? {
    (selectedSubID == nil || selectedSubID == Self.popularID) ? nil : selectedSubID
  }

  private var feedTitle: String {
    guard let id = subFilter else { return "Popular" }
    return MockData.subreddits.first { $0.id == id }?.displayName ?? "Feed"
  }

  private var posts: [MockPost] {
    let base = MockData.posts(in: subFilter)
    switch sort {
    case .hot: return base
    case .new: return base.sorted { $0.createdOffset < $1.createdOffset }
    case .top: return base.sorted { $0.score > $1.score }
    }
  }

  private var selectedPost: MockPost? {
    guard let selectedPostID else { return nil }
    return MockData.feed.first { $0.id == selectedPostID }
  }

  private var selectedCommunity: MockSubreddit? {
    guard let id = subFilter else { return nil }
    return MockData.subreddits.first { $0.id == id }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 320)
    } content: {
      AuroraFeed(posts: posts, title: feedTitle, community: selectedCommunity,
                 selectedPostID: $selectedPostID, sort: $sort)
        .navigationSplitViewColumnWidth(min: 360, ideal: 440)
    } detail: {
      if let selectedPost {
        AuroraPostDetail(post: selectedPost)
      } else {
        AuroraDetailPlaceholder()
      }
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.auroraTheme, theme)
    .tint(theme.accent)
    .fontDesign(theme.fontDesign)
    .preferredColorScheme(theme.colorScheme)
    .background { AuroraBackdrop(theme: theme) }
    .toolbarBackground(.hidden, for: .navigationBar)
    .designLabImageSession()
    .overlay(alignment: .topTrailing) {
      DesignLabClose(tint: theme.onGlass) { onClose() }
        .padding(.top, 8)
        .padding(.trailing, 14)
    }
    .onChange(of: sort) { _, _ in dropStaleSelection() }
    .onChange(of: selectedSubID) { _, _ in dropStaleSelection() }
  }

  private func dropStaleSelection() {
    if let pid = selectedPostID, !posts.contains(where: { $0.id == pid }) {
      selectedPostID = nil
    }
  }

  private var sidebar: some View {
    List(selection: $selectedSubID) {
      Section {
        Label("Popular", systemImage: "flame.fill")
          .tag(Self.popularID)
          .listRowBackground(Color.clear)
      }
      Section("Communities") {
        ForEach(MockData.subreddits) { sub in
          HStack(spacing: 10) {
            AuroraSubIcon(sub: sub, size: 26)
            VStack(alignment: .leading, spacing: 1) {
              Text(sub.displayName).font(.subheadline.weight(.medium))
              Text("\(MockFormatting.compactNumber(sub.members)) members")
                .font(.caption2).foregroundStyle(.secondary)
            }
          }
          .tag(sub.id)
          .listRowBackground(Color.clear)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .navigationTitle(displayName)
  }
}

struct AuroraDetailPlaceholder: View {
  @Environment(\.auroraTheme) private var theme
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "rectangle.split.2x1")
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(theme.accent)
      Text("Pick a post").font(.title3.weight(.semibold))
      Text("Open it here while the feed stays in view — the quiet luxury of the big screen.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview("Aurora · Midnight") {
  AuroraRoot(theme: .midnight, displayName: "Aurora")
}

#Preview("Solstice · Dawn") {
  AuroraRoot(theme: .dawn, displayName: "Solstice")
}

#Preview("Eclipse") {
  AuroraRoot(theme: .eclipse, displayName: "Eclipse")
}
