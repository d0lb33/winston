//
//  Info.swift
//  winston
//
//  Created by Igor Marcossi on 19/07/23.
//

import SwiftUI
import Defaults

struct SubredditInfoTab: View {
  @ObservedObject var subreddit: Subreddit
  @State private var loading = true
  @State private var aboutLoading = false
  @State private var aboutSummary: SubredditAboutSummary?
  @Default(.useGraphQLAPI) private var useGraphQLAPI

  var body: some View {
    if let data = subreddit.data {
      SubredditAboutStats(
        subscribers: aboutSummary?.subscribers ?? data.subscribers,
        activeUsers: aboutSummary?.activeUsers ?? data.accounts_active,
        createdAt: aboutSummary?.createdAt ?? data.created.map { Date(timeIntervalSince1970: $0) },
        loadingActiveUsers: loading
      )
      .onAppear {
        if loading {
          Task(priority: .background) {
            await subreddit.refreshSubreddit()
            await MainActor.run {
              loading = false
            }
          }
        }
      }

      SubredditDescriptionSection(
        description: bestDescription(data: data, aboutSummary: aboutSummary)
      )

      if useGraphQLAPI {
        SubredditAboutBundleSection(summary: aboutSummary, loading: aboutLoading)
          .task(priority: .background) {
            await loadAbout(data: data)
          }
      }
    }
  }

  private func bestDescription(data: SubredditData, aboutSummary: SubredditAboutSummary?) -> String {
    if let description = aboutSummary?.publicDescription, !description.isEmpty {
      return description
    }
    return data.public_description == "" ? data.description ?? "" : data.public_description
  }

  private func loadAbout(data: SubredditData) async {
    guard !aboutLoading, aboutSummary == nil else { return }
    aboutLoading = true
    let name = data.display_name ?? subreddit.id
    let subredditID = data.name.hasPrefix("t5_") ? data.name : "t5_\(data.name)"
    let summary = await RedditWire.shared.subredditAbout(name: name, subredditID: subredditID)
    await MainActor.run {
      aboutSummary = summary
      aboutLoading = false
    }
  }
}

private struct SubredditAboutStats: View {
  let subscribers: Int?
  let activeUsers: Int?
  let createdAt: Date?
  let loadingActiveUsers: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        DataBlock(icon: "person.3.fill", label: "Subscribers", value: "\(formatBigNumber(subscribers ?? 0))")
        DataBlock(
          icon: "app.connected.to.app.below.fill",
          label: "Online",
          value: loadingActiveUsers ? "loading..." : "\(formatBigNumber(activeUsers ?? 0))"
        )
      }

      if let createdAt {
        Label("Created \(createdAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
          .fontSize(14, .medium)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct SubredditDescriptionSection: View {
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Description")
        .fontSize(20, .bold)
        .frame(maxWidth: .infinity, alignment: .leading)

      if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("No description yet.")
          .foregroundStyle(.secondary)
      } else {
        Text(description.md())
          .frame(maxWidth: .infinity, alignment: .leading)
          .multilineTextAlignment(.leading)
      }
    }
  }
}

private struct SubredditAboutBundleSection: View {
  let summary: SubredditAboutSummary?
  let loading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text("About")
          .fontSize(20, .bold)
        if loading {
          ProgressView()
            .scaleEffect(0.8)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let summary, summary.hasExtraContent {
        if !summary.statusTiles.isEmpty {
          SubredditAboutTileGrid(tiles: summary.statusTiles)
        }

        if let wikiExcerpt = summary.wikiExcerpt {
          SubredditAboutTextCard(title: "Wiki", text: wikiExcerpt, systemImage: "book.closed.fill")
        }

        ForEach(summary.highlights) { section in
          SubredditAboutTextCard(title: section.title, text: section.body, systemImage: section.systemImage)
        }

        ForEach(summary.widgets) { section in
          SubredditAboutTextCard(title: section.title, text: section.body, systemImage: section.systemImage)
        }
      } else if loading {
        Text("Loading About details...")
          .foregroundStyle(.secondary)
      } else {
        Text("No extra About details found.")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct SubredditAboutTileGrid: View {
  let tiles: [SubredditAboutSummary.Tile]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
      ForEach(tiles) { tile in
        SubredditAboutTile(tile: tile)
      }
    }
  }
}

private struct SubredditAboutTile: View {
  let tile: SubredditAboutSummary.Tile

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: tile.systemImage)
        .fontSize(16, .semibold)
        .foregroundColor(.accentColor)
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(tile.title)
          .fontSize(12, .medium)
          .foregroundStyle(.secondary)
        Text(tile.value)
          .fontSize(15, .semibold)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.all, 10)
    .frame(minHeight: 58)
    .themedListRowLikeBG()
    .mask(RR(12, Color.black))
  }
}

private struct SubredditAboutTextCard: View {
  let title: String
  let text: String
  let systemImage: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .fontSize(15, .semibold)

      Text(text.md())
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
    .padding(.all, 12)
    .themedListRowLikeBG()
    .mask(RR(12, Color.black))
  }
}
