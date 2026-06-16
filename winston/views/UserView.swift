//
//  UserView.swift
//  winston
//
//  Created by Igor Marcossi on 01/07/23.
//

import SwiftUI
import NukeUI
import Defaults

struct UserViewContextPreview: View {
  var author: String
  var body: some View {
    NavigationStack { UserView(user: User(id: author)) }
  }
}

// MARK: - Profile tabs

enum ProfileTab: String, CaseIterable, Identifiable {
  case overview, posts, comments, about

  var id: String { rawValue }

  /// Public tabs shown for any user's profile.
  static let publicTabs: [ProfileTab] = [.overview, .posts, .comments, .about]

  var title: String {
    switch self {
    case .overview: return "Overview"
    case .posts: return "Posts"
    case .comments: return "Comments"
    case .about: return "About"
    }
  }

  /// The `userOverviewData` filter string for feed-backed tabs, or `nil` for
  /// non-feed tabs (About).
  var feedFilter: String? {
    switch self {
    case .overview: return ""
    case .posts: return "posts"
    case .comments: return "comments"
    case .about: return nil
    }
  }

  var isFeed: Bool { feedFilter != nil }
}

/// Per-tab feed/pagination state so each feed tab loads and pages independently.
private struct ProfileFeedState {
  var items: [Either<Post, Comment>] = []
  var loading = false
  var loadingNext = false
  var reachedEnd = false
  var lastItemId: String? = nil
  var loadedOnce = false
}

struct UserView: View {
  @StateObject var user: User
  @State private var extras: UserProfileExtras?
  @State private var selectedTab: ProfileTab = .overview
  @State private var feeds: [ProfileTab: ProfileFeedState] = [:]
  @State private var contentWidth: CGFloat = 0
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  init(user: User) {
    _user = StateObject(wrappedValue: user)
  }

#if DEBUG
  /// Preview-only initializer that seeds the fetched state so the screen renders
  /// without a live Reddit session.
  fileprivate init(previewUser: User, extras: UserProfileExtras?, tab: ProfileTab) {
    _user = StateObject(wrappedValue: previewUser)
    _extras = State(initialValue: extras)
    _selectedTab = State(initialValue: tab)
  }
#endif

  private var availableTabs: [ProfileTab] { ProfileTab.publicTabs }

  /// The profile's own brand color (from styles), used to tint the header and
  /// active tab; `nil` falls back to the app theme accent.
  private var profileAccent: Color? {
    profileAccentColor(from: extras?.primaryColor ?? user.data?.subreddit?.primary_color)
  }

  private func feed(_ tab: ProfileTab) -> ProfileFeedState { feeds[tab] ?? ProfileFeedState() }

  /// Only submitted/comment feeds support cursor paging; the mixed overview is
  /// a single non-paged batch (matches `RedditWire.userOverviewData`).
  private func canPage(_ tab: ProfileTab) -> Bool { tab == .posts || tab == .comments }

  func refreshProfile() async {
    let newExtras = await user.refetchUserBundle()
    await MainActor.run {
      withAnimation {
        self.extras = newExtras
        self.feeds = [:]
      }
    }
    await loadFeed(selectedTab, reset: true)
  }

  func loadFeed(_ tab: ProfileTab, reset: Bool = false) async {
    guard let filter = tab.feedFilter else { return }
    if !reset, feed(tab).loadedOnce { return }

    await MainActor.run {
      var state = reset ? ProfileFeedState() : feed(tab)
      state.loading = state.items.isEmpty
      feeds[tab] = state
    }

    if let result = await user.refetchOverview(filter, nil) {
      await MainActor.run {
        withAnimation {
          var state = feed(tab)
          state.items = result
          state.loading = false
          state.loadedOnce = true
          state.reachedEnd = result.isEmpty || !canPage(tab)
          state.lastItemId = canPage(tab) ? result.last.map { getItemId(for: $0) } : nil
          feeds[tab] = state
        }
      }
      await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: result, avatarSize: AuroraPostPresentation.avatarSize)
    } else {
      await MainActor.run {
        withAnimation {
          var state = feed(tab)
          state.loading = false
          state.loadedOnce = true
          state.reachedEnd = true
          feeds[tab] = state
        }
      }
    }
  }

  func loadNextFeed(_ tab: ProfileTab) {
    guard canPage(tab), let filter = tab.feedFilter else { return }
    let state = feed(tab)
    guard !state.loading, !state.loadingNext, !state.reachedEnd, let lastId = state.lastItemId else { return }

    feeds[tab]?.loadingNext = true
    Task {
      if let result = await user.refetchOverview(filter, lastId) {
        await MainActor.run {
          withAnimation {
            var state = feed(tab)
            if result.isEmpty {
              state.reachedEnd = true
              state.lastItemId = nil
            } else {
              state.items.append(contentsOf: result)
              state.lastItemId = result.last.map { getItemId(for: $0) }
            }
            state.loadingNext = false
            feeds[tab] = state
          }
        }
        if !result.isEmpty {
          await RedditWire.shared.updateOverviewSubjectsWithAvatar(subjects: result, avatarSize: AuroraPostPresentation.avatarSize)
        }
      } else {
        await MainActor.run {
          withAnimation {
            var state = feed(tab)
            state.loadingNext = false
            state.reachedEnd = true
            state.lastItemId = nil
            feeds[tab] = state
          }
        }
      }
    }
  }

  var body: some View {
    List {
      if let data = user.data {
        Section {
          UserHeaderNative(data: data, extras: extras, accent: profileAccent, contentWidth: $contentWidth)
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          UserStatsRow(data: data, extras: extras)
            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        Section {
          tabContent(for: selectedTab, data: data)
        } header: {
          ProfileTabBar(selection: $selectedTab, tabs: availableTabs, accent: profileAccent)
            .listRowInsets(EdgeInsets())
        }
      }
    }
    .loader(user.data == nil)
    .auroraListChrome()
    .refreshable {
      await refreshProfile()
    }
    .navigationTitle(user.data?.name ?? "Loading...")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      Task(priority: .background) {
        // `extras == nil` means we haven't fetched the profile bundle yet — do
        // it even when `user.data` was pre-populated by the navigating caller,
        // otherwise neither the overview feed nor the About tab ever loads.
        if extras == nil {
          await refreshProfile()
        }
      }
    }
    .onChange(of: selectedTab) {
      if selectedTab.isFeed, !feed(selectedTab).loadedOnce {
        Task { await loadFeed(selectedTab) }
      }
    }
  }

  @ViewBuilder
  private func tabContent(for tab: ProfileTab, data: UserData) -> some View {
    switch tab {
    case .about:
      UserAboutTab(data: data, extras: extras)
        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    default:
      feedRows(for: tab)
    }
  }

  @ViewBuilder
  private func feedRows(for tab: ProfileTab) -> some View {
    let state = feed(tab)

    ForEach(Array(state.items.enumerated()), id: \.element) { index, item in
      UserActivityRow(item: item)
        .onAppear {
          if canPage(tab), index >= max(state.items.count - 7, 0) {
            loadNextFeed(tab)
          }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    if state.items.isEmpty, !state.loading, state.loadedOnce {
      UserActivityEmptyState()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    if state.loading || state.loadingNext {
      UserActivityLoadingState()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    } else if state.reachedEnd, canPage(tab), !state.items.isEmpty {
      EndOfFeedView()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
  }
}

// MARK: - Header

private struct UserHeaderNative: View {
  let data: UserData
  let extras: UserProfileExtras?
  var accent: Color?
  @Binding var contentWidth: CGFloat
  @Environment(\.auroraTheme) private var theme

  private var hasBanner: Bool {
    data.subreddit?.banner_img?.isEmpty == false
  }

  private var isAdmin: Bool { extras?.isEmployee == true || data.is_employee == true }
  private var isPremium: Bool { data.is_gold == true }

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if let bannerImgFull = data.subreddit?.banner_img, !bannerImgFull.isEmpty, let bannerImg = URL(string: String(bannerImgFull.split(separator: "?")[0])) {
          URLImage(url: bannerImg)
            .scaledToFill()
            .frame(width: contentWidth, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        } else {
          let bannerAccent = accent ?? theme.accent
          RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [bannerAccent.opacity(0.38), bannerAccent.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(height: 92)
        }

        if let iconFull = data.subreddit?.icon_img ?? data.snoovatar_img ?? data.icon_img, !iconFull.isEmpty, let icon = URL(string: String(iconFull.split(separator: "?")[0])) {
          URLImage(url: icon)
            .scaledToFill()
            .frame(width: 124, height: 124)
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .offset(y: hasBanner ? 80 : 0)
        } else {
          AuroraAvatar(name: data.name, size: 124)
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .offset(y: hasBanner ? 80 : 0)
        }
      }
      .frame(maxWidth: .infinity)
      .background(
        GeometryReader { geo in
          Color.clear.onAppear { contentWidth = geo.size.width }
        }
      )
      .padding(.bottom, hasBanner ? 76 : 0)

      VStack(spacing: 6) {
        Text("u/\(data.name)")
          .font(.title3.weight(.bold))

        if isAdmin || isPremium {
          HStack(spacing: 6) {
            if isAdmin { ProfileBadge(text: "Admin", systemImage: "shield.lefthalf.filled", tint: .red) }
            if isPremium { ProfileBadge(text: "Premium", systemImage: "star.circle.fill", tint: .orange) }
          }
        }

        if let description = data.subreddit?.public_description, !description.isEmpty {
          Text(description.md())
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 8)
    }
  }
}

private struct ProfileBadge: View {
  let text: String
  let systemImage: String
  var tint: Color
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(tint.opacity(0.18), in: Capsule())
      .foregroundStyle(tint)
  }
}

// MARK: - Stats

private struct UserStatsRow: View {
  let data: UserData
  let extras: UserProfileExtras?

  private var trophyCount: Int? {
    if let total = extras?.trophyTotal, total > 0 { return total }
    if let count = extras?.trophies.count, count > 0 { return count }
    return nil
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        if let postKarma = data.link_karma {
          AuroraMetricTile(icon: "highlighter", label: "Post karma", value: formatBigNumber(postKarma))
        }
        if let commentKarma = data.comment_karma {
          AuroraMetricTile(icon: "checkmark.message.fill", label: "Comment karma", value: formatBigNumber(commentKarma))
        }
      }

      HStack(spacing: 10) {
        if let created = data.created {
          AuroraMetricTile(
            icon: "birthday.cake.fill",
            label: "Cake day",
            value: Date(timeIntervalSince1970: TimeInterval(created)).toFormat("MMM d, yyyy")
          )
        }
        if let trophyCount {
          AuroraMetricTile(icon: "trophy.fill", label: "Trophies", value: "\(trophyCount)")
        }
      }
    }
  }
}

// MARK: - Tab bar

private struct ProfileTabBar: View {
  @Binding var selection: ProfileTab
  let tabs: [ProfileTab]
  var accent: Color?
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    let tint = accent ?? theme.accent
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(tabs) { tab in
          let active = tab == selection
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
          } label: {
            Text(tab.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(active ? tint : .secondary)
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(active ? tint.opacity(0.16) : theme.cardFill, in: Capsule())
              .overlay(Capsule().stroke(active ? tint.opacity(0.7) : theme.hairline, lineWidth: 0.7))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .background(.bar)
  }
}

// MARK: - About tab

private struct UserAboutTab: View {
  let data: UserData
  let extras: UserProfileExtras?
  @Environment(\.auroraTheme) private var theme

  private var bio: String? {
    let desc = data.subreddit?.public_description
    return (desc?.isEmpty == false) ? desc : nil
  }

  private var hasAnything: Bool {
    bio != nil
      || !(extras?.trophies.isEmpty ?? true)
      || !(extras?.activeCommunities.isEmpty ?? true)
      || !(extras?.moderatedCommunities.isEmpty ?? true)
      || !(extras?.socialLinks.isEmpty ?? true)
      || extras?.postCount != nil
      || extras?.commentCount != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if extras == nil {
        HStack {
          Spacer()
          ProgressView().progressViewStyle(.circular)
          Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 100)
      } else {
        if let bio {
          aboutCard {
            VStack(alignment: .leading, spacing: 6) {
              sectionTitle("Bio")
              Text(bio.md())
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }

        if let postCount = extras?.postCount, let commentCount = extras?.commentCount {
          aboutCard {
            HStack(spacing: 24) {
              contributionStat(value: postCount, label: "Posts")
              contributionStat(value: commentCount, label: "Comments")
              Spacer()
            }
          }
        }

        if let trophies = extras?.trophies, !trophies.isEmpty {
          ProfileTrophyShelf(trophies: trophies)
        }

        if let communities = extras?.activeCommunities, !communities.isEmpty {
          ProfileCommunitiesSection(title: "Active in", communities: communities)
        }

        if let moderated = extras?.moderatedCommunities, !moderated.isEmpty {
          ProfileCommunitiesSection(title: "Moderator of", communities: moderated)
        }

        if let links = extras?.socialLinks, !links.isEmpty {
          ProfileSocialLinksSection(links: links)
        }

        if !hasAnything {
          ContentUnavailableView("Nothing here yet", systemImage: "person.crop.circle")
            .frame(maxWidth: .infinity, minHeight: 160)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func contributionStat(value: Int, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(formatBigNumber(value))
        .font(.title3.weight(.bold))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func aboutCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.hairline, lineWidth: 0.7))
  }
}

private func sectionTitle(_ text: String) -> some View {
  Text(text)
    .font(.headline.weight(.semibold))
    .frame(maxWidth: .infinity, alignment: .leading)
}

/// Parse a Reddit `#RRGGBB`/`#RRGGBBAA` style color, returning `nil` for empty
/// or malformed values (so callers can fall back to the theme accent rather
/// than rendering `UIColor(hex:)`'s black default).
private func profileAccentColor(from hex: String?) -> Color? {
  guard var trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
  if trimmed.hasPrefix("#") { trimmed.removeFirst() }
  guard trimmed.count == 6 || trimmed.count == 8, UInt64(trimmed, radix: 16) != nil else { return nil }
  return Color(uiColor: UIColor(hex: trimmed))
}

// MARK: - Trophies

private struct ProfileTrophyShelf: View {
  let trophies: [UserTrophy]
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Trophies")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(trophies) { trophy in
            TrophyCard(trophy: trophy)
          }
        }
      }
    }
  }
}

private struct TrophyCard: View {
  let trophy: UserTrophy
  @Environment(\.auroraTheme) private var theme

  var body: some View {
    VStack(spacing: 8) {
      if let iconURL = trophy.iconURL, let url = URL(string: iconURL) {
        URLImage(url: url)
          .scaledToFit()
          .frame(width: 46, height: 46)
      } else {
        Image(systemName: "trophy.fill")
          .font(.title)
          .foregroundStyle(theme.accent)
          .frame(width: 46, height: 46)
      }
      Text(trophy.name)
        .font(.caption2.weight(.medium))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .foregroundStyle(.primary)
    }
    .frame(width: 92)
    .padding(.vertical, 12)
    .padding(.horizontal, 8)
    .background(theme.cardFill, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous).stroke(theme.hairline, lineWidth: 0.7))
  }
}

// MARK: - Communities

private struct ProfileCommunitiesSection: View {
  let title: String
  let communities: [ProfileActiveCommunity]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle(title)
      VStack(spacing: 8) {
        ForEach(communities) { community in
          CommunityRow(community: community)
        }
      }
    }
  }
}

private struct CommunityRow: View {
  let community: ProfileActiveCommunity
  @Environment(\.auroraTheme) private var theme
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  private var subtitle: String? {
    var parts: [String] = []
    if let subs = community.subscribers, subs > 0 { parts.append("\(formatBigNumber(subs)) members") }
    if let active = community.weeklyActiveUsers, active > 0 { parts.append("\(formatBigNumber(active)) active") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var body: some View {
    Button {
      navigateRedditDestination(.reddit(.subFeed(Subreddit(id: community.name))), model: redditNavigationModel, origin: redditNavigationOrigin)
    } label: {
      HStack(spacing: 12) {
        Group {
          if let iconURL = community.iconURL, let url = URL(string: iconURL) {
            URLImage(url: url).scaledToFill()
          } else {
            AuroraSubIcon(name: community.name, iconKit: nil, size: 38)
          }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text(community.displayPrefixedName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(theme.cardFill, in: RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 16), style: .continuous).stroke(theme.hairline, lineWidth: 0.7))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Social links

private struct ProfileSocialLinksSection: View {
  let links: [ProfileSocialLink]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Links")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(links) { link in
            SocialLinkChip(link: link)
          }
        }
      }
    }
  }
}

private struct SocialLinkChip: View {
  let link: ProfileSocialLink
  @Environment(\.auroraTheme) private var theme
  @Environment(\.openURL) private var openURL

  private var label: String {
    link.title ?? link.handle ?? link.type?.capitalized ?? "Link"
  }

  var body: some View {
    Button {
      if let urlString = link.url, let url = URL(string: urlString) {
        openURL(url)
      }
    } label: {
      Label(label, systemImage: "link")
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.chipFill, in: Capsule())
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Activity rows

private struct UserActivityRow: View {
  let item: Either<Post, Comment>
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  var body: some View {
    switch item {
    case .first(let post):
      AuroraPostResultRow(post: post, availableRowWidth: nil) { post in
        navigateRedditDestination(.reddit(.post(post)), model: redditNavigationModel, origin: redditNavigationOrigin)
      }
    case .second(let comment):
      AuroraCommentResultRow(comment: comment) { comment in
        openCommentPost(comment)
      }
      .padding(.horizontal, 14)
    }
  }

  private func openCommentPost(_ comment: Comment) {
    guard let data = comment.data, let linkID = data.link_id, let subID = data.subreddit else { return }
    navigateRedditDestination(.reddit(.postHighlighted(Post(id: linkID, subID: subID), comment.id)), model: redditNavigationModel, origin: redditNavigationOrigin)
  }
}

private struct UserActivityEmptyState: View {
  var body: some View {
    ContentUnavailableView("No activity found", systemImage: "tray")
      .frame(maxWidth: .infinity, minHeight: 160)
  }
}

private struct UserActivityLoadingState: View {
  var body: some View {
    HStack {
      Spacer()
      ProgressView()
        .progressViewStyle(.circular)
      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 100)
  }
}

#if DEBUG
private func previewProfileUser() -> User {
  let dict: [String: Any] = [
    "id": "winston_dev",
    "name": "winston_dev",
    "total_karma": 248_120,
    "link_karma": 42_500,
    "comment_karma": 156_800,
    "created": 1_500_000_000,
    "created_utc": 1_500_000_000,
    "is_gold": true,
    "subreddit": [
      "display_name": "winston_dev",
      "display_name_prefixed": "u/winston_dev",
      "public_description": "Building a fast, native Reddit client for iOS. Tap a tab to explore.",
      "banner_img": "",
      "primary_color": "#3AA8FF",
      "url": "/user/winston_dev/"
    ]
  ]
  let data = try! JSONSerialization.data(withJSONObject: dict)
  let userData = try! JSONDecoder().decode(UserData.self, from: data)
  return User(data: userData)
}

private func previewProfileExtras() -> UserProfileExtras {
  UserProfileExtras(
    trophies: [
      UserTrophy(id: "t1", name: "Verified Email", description: nil, iconURL: nil, grantedAt: nil),
      UserTrophy(id: "t2", name: "Five-Year Club", description: nil, iconURL: nil, grantedAt: nil),
      UserTrophy(id: "t3", name: "Gold Medal", description: nil, iconURL: nil, grantedAt: nil),
      UserTrophy(id: "t4", name: "Top 1% Commenter", description: nil, iconURL: nil, grantedAt: nil)
    ],
    activeCommunities: [
      ProfileActiveCommunity(id: "t5_1", name: "swift", prefixedName: "r/swift", title: "Swift", subscribers: 321_000, weeklyActiveUsers: 1_200, iconURL: nil, primaryColor: nil, isSubscribed: true),
      ProfileActiveCommunity(id: "t5_2", name: "iOSProgramming", prefixedName: "r/iOSProgramming", title: nil, subscribers: 214_000, weeklyActiveUsers: 820, iconURL: nil, primaryColor: nil, isSubscribed: false)
    ],
    moderatedCommunities: [],
    socialLinks: [
      ProfileSocialLink(id: "l1", title: "GitHub", url: "https://github.com", type: "GITHUB", handle: nil),
      ProfileSocialLink(id: "l2", title: "Mastodon", url: "https://mastodon.social", type: nil, handle: "@winston")
    ],
    postCount: 312,
    commentCount: 4_820,
    trophyTotal: 4
  )
}

#Preview("Profile · About") {
  NavigationStack {
    UserView(previewUser: previewProfileUser(), extras: previewProfileExtras(), tab: .about)
  }
}

#Preview("Profile · Header") {
  NavigationStack {
    UserView(previewUser: previewProfileUser(), extras: previewProfileExtras(), tab: .overview)
  }
}
#endif
