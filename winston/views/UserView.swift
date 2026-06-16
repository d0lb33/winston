//
//  UserView.swift
//  winston
//
//  Created by Igor Marcossi on 01/07/23.
//

import SwiftUI
import NukeUI
import Defaults
import PhotosUI
import UIKit

struct UserViewContextPreview: View {
  var author: String
  var body: some View {
    NavigationStack { UserView(user: User(id: author)) }
  }
}

// MARK: - Profile tabs

enum ProfileTab: String, CaseIterable, Identifiable {
  case overview, posts, comments, saved, upvoted, downvoted, hidden, about

  var id: String { rawValue }

  /// Tabs shown for any user's profile.
  static let publicTabs: [ProfileTab] = [.overview, .posts, .comments, .about]

  /// Additional history tabs shown only on the signed-in user's own profile.
  static let ownProfileTabs: [ProfileTab] = [.overview, .posts, .comments, .saved, .upvoted, .downvoted, .hidden, .about]

  var title: String {
    switch self {
    case .overview: return "Overview"
    case .posts: return "Posts"
    case .comments: return "Comments"
    case .saved: return "Saved"
    case .upvoted: return "Upvoted"
    case .downvoted: return "Downvoted"
    case .hidden: return "Hidden"
    case .about: return "About"
    }
  }

  /// Every tab except About is a paginated activity feed.
  var isFeed: Bool { self != .about }

  /// The signed-in-user history feed this tab maps to, if any.
  var historyKind: RedditWire.ProfileHistoryKind? {
    switch self {
    case .saved: return .saved
    case .upvoted: return .upvoted
    case .downvoted: return .downvoted
    case .hidden: return .hidden
    default: return nil
    }
  }
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
  private static let topID = "user-view-top"

  @StateObject var user: User
  let tabInteractionTab: Nav.TabIdentifier?
  let tabInteractions: TabInteractionCenter?
  @State private var extras: UserProfileExtras?
  @State private var selectedTab: ProfileTab = .overview
  @State private var feeds: [ProfileTab: ProfileFeedState] = [:]
  @State private var contentWidth: CGFloat = 0
  @State private var isFollowing: Bool?
  @State private var isBlocked: Bool?
  @State private var showBlockConfirm = false
  @State private var showEditProfile = false
  @State private var actionError: String?
  // Just-uploaded images, shown immediately while Reddit processes them server-side.
  @State private var localAvatar: UIImage?
  @State private var localBanner: UIImage?
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin

  init(user: User, tabInteractionTab: Nav.TabIdentifier? = nil, tabInteractions: TabInteractionCenter? = nil) {
    _user = StateObject(wrappedValue: user)
    self.tabInteractionTab = tabInteractionTab
    self.tabInteractions = tabInteractions
  }

#if DEBUG
  /// Preview-only initializer that seeds the fetched state so the screen renders
  /// without a live Reddit session.
  fileprivate init(previewUser: User, extras: UserProfileExtras?, tab: ProfileTab) {
    _user = StateObject(wrappedValue: previewUser)
    tabInteractionTab = nil
    tabInteractions = nil
    _extras = State(initialValue: extras)
    _selectedTab = State(initialValue: tab)
  }
#endif

  /// True when this profile belongs to the signed-in account; unlocks the
  /// Saved / Upvoted / Downvoted / Hidden history tabs.
  private var isCurrentUser: Bool {
    guard let me = RedditWire.currentUserName, !me.isEmpty else { return false }
    let name = user.data?.name ?? user.id
    return name.lowercased() == me.lowercased()
  }

  private var availableTabs: [ProfileTab] {
    isCurrentUser ? ProfileTab.ownProfileTabs : ProfileTab.publicTabs
  }

  /// The profile's own brand color (from styles), used to tint the header and
  /// active tab; `nil` falls back to the app theme accent.
  private var profileAccent: Color? {
    profileAccentColor(from: extras?.primaryColor ?? user.data?.subreddit?.primary_color)
  }

  private func feed(_ tab: ProfileTab) -> ProfileFeedState { feeds[tab] ?? ProfileFeedState() }

  /// The mixed overview is a single non-paged batch; every other feed paginates
  /// by cursor.
  private func canPage(_ tab: ProfileTab) -> Bool {
    switch tab {
    case .overview, .about: return false
    default: return true
    }
  }

  /// Fetch one page for any feed tab, routing to the overview/submitted feeds or
  /// the signed-in-user history feeds as appropriate.
  private func fetchPage(_ tab: ProfileTab, after: String?) async -> [Either<Post, Comment>]? {
    if let kind = tab.historyKind {
      return await user.refetchHistory(kind, after)
    }
    switch tab {
    case .overview: return await user.refetchOverview("", after)
    case .posts: return await user.refetchOverview("posts", after)
    case .comments: return await user.refetchOverview("comments", after)
    default: return nil
    }
  }

  func refreshProfile() async {
    let newExtras = await user.refetchUserBundle()
    await MainActor.run {
      withAnimation {
        self.extras = newExtras
        self.isFollowing = newExtras?.isFollowing
        self.isBlocked = newExtras?.isBlocked
        self.feeds = [:]
      }
    }
    await loadFeed(selectedTab, reset: true)
  }

  /// `t2_…` fullname for the viewed redditor, needed by the follow/block
  /// mutations. Nil until the profile has loaded.
  private var accountFullname: String? {
    guard let bareID = user.data?.id, !bareID.isEmpty else { return nil }
    return bareID.hasPrefix("t2_") ? bareID : "t2_\(bareID)"
  }

  private func toggleFollow() {
    guard let fullname = accountFullname else { return }
    let target = !(isFollowing ?? false)
    withAnimation { isFollowing = target }
    Task {
      if let error = await RedditWire.shared.setFollowState(accountFullname: fullname, following: target) {
        await MainActor.run {
          withAnimation { isFollowing = !target }
          actionError = error
        }
      }
    }
  }

  /// Unblock immediately; route blocking through a confirmation dialog.
  private func requestToggleBlock() {
    if isBlocked == true {
      performBlock(false)
    } else {
      showBlockConfirm = true
    }
  }

  private func performBlock(_ target: Bool) {
    guard let fullname = accountFullname else { return }
    withAnimation { isBlocked = target }
    Task {
      if let error = await RedditWire.shared.setBlockState(redditorFullname: fullname, blocked: target) {
        await MainActor.run {
          withAnimation { isBlocked = !target }
          actionError = error
        }
      }
    }
  }

  func loadFeed(_ tab: ProfileTab, reset: Bool = false) async {
    guard tab.isFeed else { return }
    if !reset, feed(tab).loadedOnce { return }

    await MainActor.run {
      var state = reset ? ProfileFeedState() : feed(tab)
      state.loading = state.items.isEmpty
      feeds[tab] = state
    }

    if let result = await fetchPage(tab, after: nil) {
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
    guard canPage(tab) else { return }
    let state = feed(tab)
    guard !state.loading, !state.loadingNext, !state.reachedEnd, let lastId = state.lastItemId else { return }

    feeds[tab]?.loadingNext = true
    Task {
      if let result = await fetchPage(tab, after: lastId) {
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
    TabScrollRoot(
      topID: Self.topID,
      tab: tabInteractionTab,
      tabInteractions: tabInteractions,
      request: tabInteractionTab.flatMap { tabInteractions?.requests[$0] }
    ) {
      if let data = user.data {
        Section {
          UserHeaderNative(
            data: data,
            extras: extras,
            accent: profileAccent,
            isCurrentUser: isCurrentUser,
            isFollowing: isFollowing,
            isBlocked: isBlocked,
            onToggleFollow: toggleFollow,
            onToggleBlock: requestToggleBlock,
            onEditProfile: { showEditProfile = true },
            localAvatar: localAvatar,
            localBanner: localBanner,
            contentWidth: $contentWidth
          )
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
    .confirmationDialog(
      "Block u/\(user.data?.name ?? "")?",
      isPresented: $showBlockConfirm,
      titleVisibility: .visible
    ) {
      Button("Block", role: .destructive) { performBlock(true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You won't see their posts or comments, and they won't be able to message you.")
    }
    .alert(
      "Couldn't complete that",
      isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let actionError { Text(actionError) }
    }
    .sheet(isPresented: $showEditProfile) {
      if let data = user.data, let subredditID = data.subreddit?.name, !subredditID.isEmpty {
        EditProfileSheet(
          subredditID: subredditID,
          username: data.name,
          initialTitle: data.subreddit?.title ?? "",
          initialBio: data.subreddit?.public_description ?? "",
          initialNSFW: data.subreddit?.over_18 ?? false,
          initialLinks: extras?.socialLinks ?? [],
          initialAvatarURL: data.snoovatar_img ?? data.subreddit?.icon_img ?? data.icon_img,
          initialBannerURL: data.subreddit?.banner_img
        ) { newAvatar, newBanner in
          if let newAvatar { localAvatar = newAvatar }
          if let newBanner { localBanner = newBanner }
          Task { await refreshProfile() }
        }
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
  var isCurrentUser: Bool = false
  var isFollowing: Bool?
  var isBlocked: Bool?
  var onToggleFollow: () -> Void = {}
  var onToggleBlock: () -> Void = {}
  var onEditProfile: () -> Void = {}
  var localAvatar: UIImage?
  var localBanner: UIImage?
  @Binding var contentWidth: CGFloat
  @Environment(\.auroraTheme) private var theme

  private var hasBanner: Bool {
    localBanner != nil || data.subreddit?.banner_img?.isEmpty == false
  }

  private var isAdmin: Bool { extras?.isEmployee == true || data.is_employee == true }
  private var isPremium: Bool { data.is_gold == true }

  /// The user's chosen display name (profile title), shown above the handle when
  /// it's set and differs from the username.
  private var displayName: String? {
    guard let title = data.subreddit?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          !title.isEmpty,
          title.lowercased() != data.name.lowercased() else { return nil }
    return title
  }

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if let localBanner {
          Image(uiImage: localBanner)
            .resizable()
            .scaledToFill()
            .frame(width: contentWidth, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        } else if let bannerImgFull = data.subreddit?.banner_img, !bannerImgFull.isEmpty, let bannerImg = URL(string: String(bannerImgFull.split(separator: "?")[0])) {
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

        if let localAvatar {
          Image(uiImage: localAvatar)
            .resizable()
            .scaledToFill()
            .frame(width: 124, height: 124)
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .offset(y: hasBanner ? 80 : 0)
        } else if let iconFull = data.subreddit?.icon_img ?? data.snoovatar_img ?? data.icon_img, !iconFull.isEmpty, let icon = URL(string: String(iconFull.split(separator: "?")[0])) {
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
        if let displayName {
          Text(displayName)
            .font(.title3.weight(.bold))
            .multilineTextAlignment(.center)
          Text("u/\(data.name)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          Text("u/\(data.name)")
            .font(.title3.weight(.bold))
        }

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

      if isCurrentUser {
        ownProfileActions
      } else {
        profileActions
      }
    }
  }

  @ViewBuilder
  private var ownProfileActions: some View {
    Button(action: onEditProfile) {
      Label("Edit Profile", systemImage: "pencil")
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(theme.cardFill, in: Capsule())
        .foregroundStyle(.primary)
        .overlay(Capsule().stroke(theme.hairline, lineWidth: 0.7))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
  }

  @ViewBuilder
  private var profileActions: some View {
    let accentColor = accent ?? theme.accent
    HStack(spacing: 10) {
      Button(action: onToggleFollow) {
        Label(isFollowing == true ? "Following" : "Follow",
              systemImage: isFollowing == true ? "checkmark" : "plus")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 9)
          .background(isFollowing == true ? theme.cardFill : accentColor, in: Capsule())
          .foregroundStyle(isFollowing == true ? Color.primary : .white)
          .overlay(Capsule().stroke(isFollowing == true ? theme.hairline : .clear, lineWidth: 0.7))
      }
      .buttonStyle(.plain)

      Menu {
        Button(role: isBlocked == true ? nil : .destructive, action: onToggleBlock) {
          Label(isBlocked == true ? "Unblock account" : "Block account",
                systemImage: isBlocked == true ? "hand.raised.slash" : "hand.raised")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.subheadline.weight(.semibold))
          .frame(width: 44, height: 38)
          .background(theme.cardFill, in: Capsule())
          .overlay(Capsule().stroke(theme.hairline, lineWidth: 0.7))
          .foregroundStyle(.primary)
      }
    }
    .padding(.horizontal, 8)
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

// MARK: - Edit profile

private struct EditableSocialLink: Identifiable {
  let id = UUID()
  var title: String = ""
  var url: String = ""
  var type: String? = nil
}

private struct EditProfileSheet: View {
  let subredditID: String
  let username: String
  let initialTitle: String
  let initialBio: String
  let initialNSFW: Bool
  let initialLinks: [ProfileSocialLink]
  let initialAvatarURL: String?
  let initialBannerURL: String?
  var onSaved: (_ avatar: UIImage?, _ banner: UIImage?) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.auroraTheme) private var theme
  @State private var title: String
  @State private var bio: String
  @State private var nsfw: Bool
  @State private var links: [EditableSocialLink]
  @State private var saving = false
  @State private var errorText: String?

  @State private var avatarItem: PhotosPickerItem?
  @State private var bannerItem: PhotosPickerItem?
  @State private var avatarData: Data?
  @State private var bannerData: Data?
  @State private var avatarPreview: UIImage?
  @State private var bannerPreview: UIImage?

  init(subredditID: String, username: String, initialTitle: String, initialBio: String, initialNSFW: Bool, initialLinks: [ProfileSocialLink], initialAvatarURL: String?, initialBannerURL: String?, onSaved: @escaping (_ avatar: UIImage?, _ banner: UIImage?) -> Void) {
    self.subredditID = subredditID
    self.username = username
    self.initialTitle = initialTitle
    self.initialBio = initialBio
    self.initialNSFW = initialNSFW
    self.initialLinks = initialLinks
    self.initialAvatarURL = initialAvatarURL
    self.initialBannerURL = initialBannerURL
    self.onSaved = onSaved
    _title = State(initialValue: initialTitle)
    _bio = State(initialValue: initialBio)
    _nsfw = State(initialValue: initialNSFW)
    _links = State(initialValue: initialLinks.map { EditableSocialLink(title: $0.title ?? "", url: $0.url ?? "", type: $0.type) })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Avatar") {
          HStack(spacing: 14) {
            avatarThumb
            PhotosPicker(selection: $avatarItem, matching: .images) {
              Text(avatarPreview == nil ? "Change avatar" : "New avatar selected")
            }
          }
        }

        Section("Banner") {
          bannerThumb
          PhotosPicker(selection: $bannerItem, matching: .images) {
            Text(bannerPreview == nil ? "Change banner" : "New banner selected")
          }
        }

        Section("Display name") {
          TextField("Display name", text: $title)
        }
        Section("Bio") {
          TextField("Bio", text: $bio, axis: .vertical)
            .lineLimit(3...8)
        }
        Section {
          Toggle("Mature (18+) profile", isOn: $nsfw)
        }
        Section("Social links") {
          ForEach($links) { $link in
            VStack(alignment: .leading, spacing: 6) {
              TextField("Label", text: $link.title)
                .font(.subheadline.weight(.semibold))
              TextField("https://…", text: $link.url)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .padding(.vertical, 2)
          }
          .onDelete { links.remove(atOffsets: $0) }
          Button {
            links.append(EditableSocialLink())
          } label: {
            Label("Add link", systemImage: "plus.circle")
          }
        }
        if let errorText {
          Section {
            Text(errorText).foregroundStyle(.red).font(.footnote)
          }
        }
      }
      .navigationTitle("Edit Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if saving {
            ProgressView()
          } else {
            Button("Save") { save() }
          }
        }
      }
      .interactiveDismissDisabled(saving)
      .onChange(of: avatarItem) { loadPickedImage(avatarItem, maxDimension: 1024, isBanner: false) }
      .onChange(of: bannerItem) { loadPickedImage(bannerItem, maxDimension: 2048, isBanner: true) }
    }
  }

  @ViewBuilder private var avatarThumb: some View {
    Group {
      if let avatarPreview {
        Image(uiImage: avatarPreview).resizable().scaledToFill()
      } else if let url = loadableURL(initialAvatarURL) {
        URLImage(url: url).scaledToFill()
      } else {
        AuroraAvatar(name: username, size: 72)
      }
    }
    .frame(width: 72, height: 72)
    .clipShape(Circle())
    .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
  }

  @ViewBuilder private var bannerThumb: some View {
    Group {
      if let bannerPreview {
        Image(uiImage: bannerPreview).resizable().scaledToFill()
      } else if let url = loadableURL(initialBannerURL) {
        URLImage(url: url).scaledToFill()
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(height: 90)
    .frame(maxWidth: .infinity)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func loadableURL(_ raw: String?) -> URL? {
    guard let raw, !raw.isEmpty else { return nil }
    let clean = String(raw.split(separator: "?").first ?? Substring(raw))
    return URL(string: clean)
  }

  private func loadPickedImage(_ item: PhotosPickerItem?, maxDimension: CGFloat, isBanner: Bool) {
    guard let item else { return }
    Task {
      guard let data = try? await item.loadTransferable(type: Data.self),
            let processed = processPickedImage(data, maxDimension: maxDimension) else { return }
      await MainActor.run {
        if isBanner {
          bannerData = processed.jpeg
          bannerPreview = processed.image
        } else {
          avatarData = processed.jpeg
          avatarPreview = processed.image
        }
      }
    }
  }

  private func save() {
    saving = true
    errorText = nil
    let trimmed = links.map {
      EditableSocialLink(
        title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
        url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines),
        type: $0.type
      )
    }
    .filter { !$0.url.isEmpty }
    let linksChanged = trimmed.map { "\($0.title)|\($0.url)" } != initialLinks.map { "\($0.title ?? "")|\($0.url ?? "")" }

    Task {
      // Each step names what it was doing so a failure explains itself.
      if let failure = await performSave(linksChanged: linksChanged, trimmedLinks: trimmed) {
        await MainActor.run {
          saving = false
          errorText = failure
        }
        return
      }
      await MainActor.run {
        saving = false
        onSaved(avatarPreview, bannerPreview)
        dismiss()
      }
    }
  }

  /// Runs the save steps in order, returning the first step's labeled error
  /// message, or nil if everything succeeded.
  private func performSave(linksChanged: Bool, trimmedLinks: [EditableSocialLink]) async -> String? {
    var iconURL: String?
    var bannerURL: String?

    if let avatarData {
      do { iconURL = try await RedditWire.shared.uploadProfileAsset(avatarData, kind: .avatar) }
      catch { return "Couldn't upload your avatar — \(RedditWire.userFacingMessage(for: error))" }
    }
    if let bannerData {
      do { bannerURL = try await RedditWire.shared.uploadProfileAsset(bannerData, kind: .banner) }
      catch { return "Couldn't upload your banner — \(RedditWire.userFacingMessage(for: error))" }
    }

    if iconURL != nil || bannerURL != nil {
      if let error = await RedditWire.shared.applyProfileStyles(iconURL: iconURL, bannerURL: bannerURL) {
        return "Couldn't apply your new photo — \(error)"
      }
    }

    if let error = await RedditWire.shared.updateProfileSettings(
      subredditID: subredditID,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      publicDescription: bio,
      isNsfw: nsfw
    ) {
      return "Couldn't save your name & bio — \(error)"
    }

    if linksChanged {
      let profileLinks = trimmedLinks.map {
        ProfileSocialLink(id: $0.id.uuidString, title: $0.title.isEmpty ? nil : $0.title, url: $0.url, type: $0.type, handle: nil)
      }
      if let error = await RedditWire.shared.setSocialLinks(profileLinks) {
        return "Couldn't save your links — \(error)"
      }
    }

    return nil
  }
}

/// Decode picked image data, downscale to fit `maxDimension`, and re-encode as
/// JPEG (Reddit's profile upload accepts JPEG/PNG; we normalize to JPEG).
private func processPickedImage(_ data: Data, maxDimension: CGFloat) -> (jpeg: Data, image: UIImage)? {
  guard let image = UIImage(data: data) else { return nil }
  let maxSide = max(image.size.width, image.size.height)
  let target: UIImage
  if maxSide > maxDimension, maxSide > 0 {
    let scale = maxDimension / maxSide
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    target = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
  } else {
    target = image
  }
  guard let jpeg = target.jpegData(compressionQuality: 0.85) else { return nil }
  return (jpeg, target)
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
      "title": "Winston Dev",
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
