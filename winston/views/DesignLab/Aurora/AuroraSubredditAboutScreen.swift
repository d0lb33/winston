//
//  AuroraSubredditAboutScreen.swift
//  winston
//
//  Aurora-styled subreddit info panel — the `.subInfo` destination routes here. It
//  reuses the existing data layer (`subredditAbout`, `fetchRules`, `refreshSubreddit`
//  and the signed-in user's submitted-posts feed) but renders everything in the Aurora
//  card idiom instead of the legacy List + theme. Three tabs mirror the old panel:
//  About (stats / description / community details + wiki), Rules, and My Posts.
//

import SwiftUI
import Defaults
import NukeUI
import MarkdownUI

private enum AuroraSubAboutTab: String, CaseIterable, Identifiable {
  case about = "About"
  case rules = "Rules"
  case myPosts = "My Posts"
  var id: String { rawValue }
}

struct AuroraSubredditAboutScreen: View {
  @ObservedObject var subreddit: Subreddit
  @Default(.auroraThemeID) private var auroraThemeID
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  @State private var selectedTab: AuroraSubAboutTab = .about

  // About
  @State private var aboutSummary: SubredditAboutSummary?
  @State private var aboutLoading = false
  @State private var statsLoaded = false

  // Rules
  @State private var rules: [SubredditRuleSummary]?
  @State private var rulesLoading = false

  // My posts (signed-in user's submissions, filtered to this community)
  @State private var myUser: User?
  @State private var myPosts: [Post] = []
  @State private var myPostsCursor: String?
  @State private var myPostsLoading = false
  @State private var myPostsLoadingNext = false
  @State private var myPostsReachedEnd = false
  @State private var myPostsLoadedOnce = false

  @State private var isFavorited = false

  private var theme: AuroraTheme { auroraThemeID.theme }
  private var subName: String { subreddit.data?.display_name ?? subreddit.id }

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        header
        AuroraSubAboutTabBar(selection: $selectedTab, accent: theme.accent)
        switch selectedTab {
        case .about: aboutSection
        case .rules: rulesSection
        case .myPosts: myPostsSection
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 6)
      .padding(.bottom, 28)
    }
    .scrollContentBackground(.hidden)
    .background { AuroraBackdrop(theme: theme) }
    .environment(\.auroraTheme, theme)
    .tint(theme.accent)
    .navigationTitle(subreddit.displayTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar { ToolbarItem(placement: .topBarTrailing) { favoriteButton } }
    .task {
      if !statsLoaded {
        await subreddit.refreshSubreddit()
        statsLoaded = true
      }
      await loadAboutIfNeeded()
    }
    .onChange(of: selectedTab) { _, tab in Task { await load(for: tab) } }
    .onAppear { isFavorited = subreddit.data?.user_has_favorited ?? isFavorited }
    .onChange(of: subreddit.data?.user_has_favorited ?? false) { _, fav in
      withAnimation { isFavorited = fav }
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(spacing: 0) {
      if let banner = bannerURL {
        LazyImage(url: banner) { state in
          if let image = state.image {
            image.resizable().scaledToFill()
          } else {
            LinearGradient(colors: [theme.accent.opacity(0.5), theme.chipFill], startPoint: .topLeading, endPoint: .bottomTrailing)
          }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipped()
      }
      VStack(spacing: 10) {
        AuroraSubIcon(name: subName, iconKit: subreddit.data?.subredditIconKit, size: 64)
          .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
        VStack(spacing: 3) {
          Text("r/\(subName)").font(.title3.weight(.bold)).multilineTextAlignment(.center)
          if let created = createdDate {
            Text("Created \(created.formatted(date: .abbreviated, time: .omitted))")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        joinButton
      }
      .frame(maxWidth: .infinity)
      .padding(16)
    }
    .background(theme.cardFill)
    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7))
  }

  private var favoriteButton: some View {
    Button {
      withAnimation { isFavorited.toggle() }
      subreddit.favoriteToggle()
    } label: {
      Image(systemName: isFavorited ? "star.fill" : "star")
        .foregroundStyle(isFavorited ? .yellow : theme.accent)
    }
    .accessibilityLabel(isFavorited ? "Unfavorite" : "Favorite")
  }

  private var joinButton: some View {
    let joined = subreddit.data?.user_is_subscriber ?? false
    return Button {
      subreddit.subscribeToggle(optimistic: true)
    } label: {
      Text(joined ? "Joined" : "Join")
        .font(.subheadline.weight(.bold))
        .foregroundStyle(joined ? theme.accent : (theme.isDark ? .black : .white))
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(joined ? theme.chipFill : theme.accent, in: .capsule)
    }
    .buttonStyle(.plain)
  }

  // MARK: About tab

  private var aboutSection: some View {
    VStack(spacing: 14) {
      statsCard
      descriptionCard
      if aboutLoading && aboutSummary == nil {
        loadingRow("Loading community details…")
      }
      aboutBundle
    }
  }

  private var statsCard: some View {
    AuroraInfoCard {
      HStack(spacing: 12) {
        statTile(icon: "person.3.fill", label: "Members", value: formatBigNumber(subscribersValue))
        statTile(icon: "dot.radiowaves.left.and.right", label: "Online", value: onlineValueText)
      }
    }
  }

  @ViewBuilder private var descriptionCard: some View {
    let text = bestDescription
    AuroraInfoCard {
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("Description")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("No description yet.").font(.subheadline).foregroundStyle(.secondary)
        } else {
          Markdown(MarkdownUtil.formatForMarkdown(text))
            .markdownTheme(.winstonMarkdown(fontSize: 15, lineSpacing: 2))
        }
      }
    }
  }

  @ViewBuilder private var aboutBundle: some View {
    if let summary = aboutSummary, summary.hasExtraContent {
      if !summary.statusTiles.isEmpty {
        AuroraInfoCard {
          VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Community")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
              ForEach(summary.statusTiles) { aboutTile($0) }
            }
          }
        }
      }
      if let wiki = summary.wikiExcerpt {
        aboutTextCard(title: "Wiki", text: wiki, systemImage: "book.closed.fill")
      }
      ForEach(summary.highlights) { aboutTextCard(title: $0.title, text: $0.body, systemImage: $0.systemImage) }
      ForEach(summary.widgets) { aboutTextCard(title: $0.title, text: $0.body, systemImage: $0.systemImage) }
    }
  }

  private func aboutTile(_ tile: SubredditAboutSummary.Tile) -> some View {
    HStack(spacing: 8) {
      Image(systemName: tile.systemImage)
        .font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(tile.title).font(.caption).foregroundStyle(.secondary)
        Text(tile.value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .frame(minHeight: 58)
    .background(theme.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func aboutTextCard(title: String, text: String, systemImage: String) -> some View {
    AuroraInfoCard {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent)
        Markdown(MarkdownUtil.formatForMarkdown(text))
          .markdownTheme(.winstonMarkdown(fontSize: 15, lineSpacing: 2))
      }
    }
  }

  // MARK: Rules tab

  @ViewBuilder private var rulesSection: some View {
    if rulesLoading && rules == nil {
      loadingRow("Loading rules…")
    } else if let rules, !rules.isEmpty {
      VStack(spacing: 10) {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
          ruleCard(index: index + 1, rule: rule)
        }
      }
    } else {
      emptyCard("No rules", "r/\(subName) hasn't published any rules.", icon: "checklist")
    }
  }

  private func ruleCard(index: Int, rule: SubredditRuleSummary) -> some View {
    AuroraInfoCard {
      HStack(alignment: .top, spacing: 12) {
        Text("\(index)")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(theme.isDark ? .black : .white)
          .frame(width: 26, height: 26)
          .background(theme.accent, in: Circle())
        VStack(alignment: .leading, spacing: 6) {
          Text(rule.name).font(.headline)
          let md = MarkdownUtil.formatForMarkdown(rule.markdown)
          if !md.isEmpty {
            Markdown(md).markdownTheme(.winstonMarkdown(fontSize: 14, lineSpacing: 2))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: My Posts tab

  @ViewBuilder private var myPostsSection: some View {
    if RedditWire.currentUserName == nil {
      emptyCard("Not signed in", "Sign in to see your posts in this community.", icon: "person.crop.circle.badge.questionmark")
    } else if myPostsLoading && myPosts.isEmpty {
      loadingRow("Loading your posts…")
    } else if myPosts.isEmpty && myPostsLoadedOnce {
      emptyCard("No posts", "You haven't posted in r/\(subName) yet.", icon: "tray")
    } else {
      LazyVStack(spacing: 10) {
        ForEach(Array(myPosts.enumerated()), id: \.element.id) { index, post in
          AuroraPostResultRow(post: post, availableRowWidth: nil) { tapped in
            navigateRedditDestination(.reddit(.post(tapped)), model: redditNavigationModel, origin: redditNavigationOrigin)
          }
          .onAppear {
            if index >= myPosts.count - 3 { Task { await loadMyPostsNextPage() } }
          }
        }
        if myPostsLoadingNext { loadingRow("Loading more…") }
      }
    }
  }

  // MARK: Shared pieces

  private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func statTile(icon: String, label: String, value: String) -> some View {
    VStack(spacing: 4) {
      Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(theme.accent)
      Text(value).font(.headline)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(theme.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func loadingRow(_ text: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(text).font(.subheadline).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private func emptyCard(_ title: String, _ subtitle: String, icon: String) -> some View {
    AuroraInfoCard {
      VStack(spacing: 8) {
        Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
        Text(title).font(.headline)
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
    }
  }

  // MARK: Derived values

  private var bannerURL: URL? {
    let raw = [subreddit.data?.banner_background_image, subreddit.data?.banner_img, subreddit.data?.header_img]
      .compactMap { $0 }.first { !$0.isEmpty }
    guard let raw else { return nil }
    return URL(string: raw.replacingOccurrences(of: "&amp;", with: "&"))
  }

  private var createdDate: Date? {
    if let date = aboutSummary?.createdAt { return date }
    if let created = subreddit.data?.created { return Date(timeIntervalSince1970: created) }
    return nil
  }

  private var subscribersValue: Int {
    aboutSummary?.subscribers ?? subreddit.data?.subscribers ?? 0
  }

  private var onlineValueText: String {
    if let active = aboutSummary?.activeUsers ?? subreddit.data?.accounts_active {
      return formatBigNumber(active)
    }
    return statsLoaded ? "—" : "…"
  }

  private var bestDescription: String {
    if let description = aboutSummary?.publicDescription, !description.isEmpty { return description }
    let publicDescription = subreddit.data?.public_description ?? ""
    return publicDescription.isEmpty ? (subreddit.data?.description ?? "") : publicDescription
  }

  // MARK: Loading

  @MainActor
  private func load(for tab: AuroraSubAboutTab) async {
    switch tab {
    case .about: await loadAboutIfNeeded()
    case .rules: await loadRulesIfNeeded()
    case .myPosts: await loadMyPostsFirstPageIfNeeded()
    }
  }

  @MainActor
  private func loadAboutIfNeeded() async {
    guard aboutSummary == nil, !aboutLoading, let data = subreddit.data else { return }
    aboutLoading = true
    let name = data.display_name ?? subreddit.id
    let subredditID = data.name.hasPrefix("t5_") ? data.name : "t5_\(data.name)"
    let summary = await RedditWire.shared.subredditAbout(name: name, subredditID: subredditID)
    aboutSummary = summary
    aboutLoading = false
  }

  @MainActor
  private func loadRulesIfNeeded() async {
    guard rules == nil, !rulesLoading else { return }
    rulesLoading = true
    let fetched = await subreddit.fetchRules()
    rules = fetched ?? []
    rulesLoading = false
  }

  @MainActor
  private func ensureMyUser() -> User? {
    if let myUser { return myUser }
    guard let name = RedditWire.currentUserName, !name.isEmpty else { return nil }
    let user = User(id: name)
    myUser = user
    return user
  }

  @MainActor
  private func loadMyPostsFirstPageIfNeeded() async {
    guard !myPostsLoadedOnce, !myPostsLoading else { return }
    guard let user = ensureMyUser() else { myPostsLoadedOnce = true; return }
    myPostsLoading = true
    // The submitted-posts feed is global, so page a bounded number of times until we
    // surface some posts from this community (or run out) — otherwise an empty first
    // page would leave no row to trigger further paging.
    var pages = 0
    var cursor: String? = nil
    while pages < 5 {
      let advanced = await fetchMyPostsPage(user: user, after: cursor, reset: pages == 0)
      pages += 1
      cursor = myPostsCursor
      if !advanced || myPostsReachedEnd || !myPosts.isEmpty { break }
    }
    myPostsLoading = false
    myPostsLoadedOnce = true
  }

  @MainActor
  private func loadMyPostsNextPage() async {
    guard myPostsLoadedOnce, !myPostsLoadingNext, !myPostsReachedEnd,
          let user = myUser, let cursor = myPostsCursor else { return }
    myPostsLoadingNext = true
    await fetchMyPostsPage(user: user, after: cursor, reset: false)
    myPostsLoadingNext = false
  }

  @MainActor
  @discardableResult
  private func fetchMyPostsPage(user: User, after: String?, reset: Bool) async -> Bool {
    guard let result = await user.refetchOverview("posts", after) else {
      myPostsReachedEnd = true
      return false
    }
    if reset { myPosts = [] }
    let target = subName.lowercased()
    var seen = Set(myPosts.map { $0.id })
    for item in result {
      if case .first(let post) = item,
         (post.data?.subreddit.lowercased() ?? "") == target,
         !seen.contains(post.id) {
        myPosts.append(post)
        seen.insert(post.id)
      }
    }
    myPostsCursor = result.last.map { getItemId(for: $0) }
    myPostsReachedEnd = result.isEmpty
    return !result.isEmpty
  }
}

// MARK: - Tab bar

private struct AuroraSubAboutTabBar: View {
  @Binding var selection: AuroraSubAboutTab
  var accent: Color
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      ForEach(AuroraSubAboutTab.allCases) { tab in
        let active = tab == selection
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
        } label: {
          Text(tab.rawValue)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? accent : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? accent.opacity(0.16) : theme.cardFill, in: Capsule())
            .overlay(Capsule().stroke(active ? accent.opacity(0.7) : theme.hairline, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Card container

private struct AuroraInfoCard<Content: View>: View {
  @Environment(\.auroraTheme) private var theme
  var padding: CGFloat = 16
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7))
  }
}
