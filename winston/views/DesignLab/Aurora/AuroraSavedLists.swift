//
//  AuroraSavedLists.swift
//  winston
//

import SwiftUI

enum SavedListsOverviewMode {
  case manage
  case picker
}

struct SavedListsOverviewScreen: View {
  let mode: SavedListsOverviewMode
  let onListSelected: (SavedListSummary) -> Void
  var onPostSelected: (Post) -> Void = { _ in }
  var onCommentSelected: (Comment) -> Void = { _ in }

  @State private var lists: [SavedListSummary] = []
  @State private var newListName = ""
  @State private var creatingList = false
  @State private var renameList: SavedListSummary?
  @State private var renameText = ""

  private let store = SavedListsStore.shared

  var body: some View {
    List {
      if lists.isEmpty {
        SavedListsEmptySection()
      } else {
        Section {
          ForEach(lists) { list in
            SavedListOverviewRow(
              list: list,
              mode: mode,
              onPick: { onListSelected(list) },
              onRename: {
                renameList = list
                renameText = list.name
              },
              onFavoriteToggle: {
                store.setFavorite(!list.favorited, listID: list.id)
                reload()
              },
              onDelete: {
                store.deleteList(id: list.id)
                reload()
              },
              destination: {
                SavedListDetailScreen(
                  listID: list.id,
                  onPostSelected: onPostSelected,
                  onCommentSelected: onCommentSelected
                )
              }
            )
          }
        }
      }
    }
    .navigationTitle(mode == .picker ? "Choose List" : "Saved Lists")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          creatingList = true
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("New List")
      }
    }
    .alert("New List", isPresented: $creatingList) {
      TextField("List name", text: $newListName)
      Button("Create") {
        _ = store.createList(named: newListName)
        newListName = ""
        reload()
      }
      Button("Cancel", role: .cancel) {
        newListName = ""
      }
    }
    .alert("Rename List", isPresented: Binding(get: { renameList != nil }, set: { if !$0 { renameList = nil } })) {
      TextField("List name", text: $renameText)
      Button("Save") {
        if let renameList {
          store.renameList(id: renameList.id, name: renameText)
        }
        renameList = nil
        renameText = ""
        reload()
      }
      Button("Cancel", role: .cancel) {
        renameList = nil
        renameText = ""
      }
    }
    .overlay {
      if lists.isEmpty {
        ContentUnavailableView("No saved lists", systemImage: "list.bullet.rectangle")
      }
    }
    .onAppear { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
      reload()
    }
  }

  private func reload() {
    lists = store.summaries()
  }
}

private struct SavedListsEmptySection: View {
  var body: some View {
    Section {
      EmptyView()
    }
  }
}

private struct SavedListOverviewRow<Destination: View>: View {
  let list: SavedListSummary
  let mode: SavedListsOverviewMode
  let onPick: () -> Void
  let onRename: () -> Void
  let onFavoriteToggle: () -> Void
  let onDelete: () -> Void
  @ViewBuilder let destination: () -> Destination

  var body: some View {
    switch mode {
    case .picker:
      Button(action: onPick) {
        SavedListOverviewRowContent(name: list.name, count: list.count, lastUsedAt: list.lastUsedAt, favorited: list.favorited)
      }
    case .manage:
      NavigationLink {
        destination()
      } label: {
        SavedListOverviewRowContent(name: list.name, count: list.count, lastUsedAt: list.lastUsedAt, favorited: list.favorited)
      }
      .contextMenu {
        Button(list.favorited ? "Unfavorite" : "Favorite", systemImage: list.favorited ? "star.slash" : "star", action: onFavoriteToggle)
        Button("Rename", systemImage: "pencil", action: onRename)
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
      }
    }
  }
}

private struct SavedListOverviewRowContent: View {
  let name: String
  let count: Int
  let lastUsedAt: Date?
  let favorited: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: favorited ? "star.fill" : "folder.fill")
        .foregroundStyle(Color.accentColor)
        .font(.title3)
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        HStack(spacing: 8) {
          Text("\(count) items")
          if let lastUsedAt {
            Text(lastUsedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
}

struct SavedListDetailScreen: View {
  private static let hydrationBatchSize = 20

  let listID: UUID
  let onPostSelected: (Post) -> Void
  let onCommentSelected: (Comment) -> Void

  @State private var list: SavedListSummary?
  @State private var items: [SavedListItemSummary] = []
  @State private var hydratedPosts: [String: Post] = [:]
  @State private var hydratingFullnames: Set<String> = []

  private let store = SavedListsStore.shared

  var body: some View {
    GeometryReader { geometry in
      let rowWidth = max(1, geometry.size.width)
      List {
        if items.isEmpty {
          Section {
            EmptyView()
          }
        } else {
          Section(header: AuroraResultSectionHeader(title: "Items", count: items.count)) {
            ForEach(items) { item in
              SavedListItemRow(
                item: item,
                rowWidth: rowWidth,
                hydratedPost: hydratedPost(for: item),
                hydrate: {
                  hydrateBatch(startingAt: item, contentWidth: rowWidth)
                },
                remove: {
                  store.remove(itemID: item.id)
                  reload()
                },
                selectPost: onPostSelected,
                selectComment: onCommentSelected
              )
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
            }
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .driveInlineVideoCoordinator(coordinateSpace: "savedListFeed", posts: hydratedPostsForInlineVideo)
      .overlay {
        if items.isEmpty {
          ContentUnavailableView("No saved items", systemImage: "bookmark")
        }
      }
    }
    .navigationTitle(list?.name ?? "Saved List")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
      reload()
    }
  }

  private var hydratedPostsForInlineVideo: [Post] {
    items.compactMap { item in
      guard item.kind == .post else { return nil }
      return hydratedPost(for: item)
    }
  }

  private func reload() {
    list = store.listSummary(id: listID)
    items = store.items(in: listID)
    hydratedPosts = hydratedPosts.filter { fullname, _ in
      items.contains { $0.fullname == fullname }
    }
    hydratingFullnames = hydratingFullnames.filter { fullname in
      items.contains { $0.fullname == fullname }
    }
  }

  private func hydrateBatch(startingAt item: SavedListItemSummary, contentWidth: CGFloat) {
    guard item.kind == .post else { return }
    let postItems = items.filter { $0.kind == .post }
    guard let startIndex = postItems.firstIndex(where: { $0.id == item.id }) else { return }

    let batch = postItems
      .dropFirst(startIndex)
      .prefix(Self.hydrationBatchSize)
      .filter { hydratedPost(for: $0) == nil && !hydratingFullnames.contains($0.fullname) }

    guard !batch.isEmpty else { return }
    let fullnames = batch.map(\.fullname)
    hydratingFullnames.formUnion(fullnames)
    AppDiagnostics.asyncRecord(
      .info,
      category: "savedLists.hydration",
      message: "Hydrating saved-list post batch",
      metadata: [
        "listID": listID.uuidString,
        "startFullname": item.fullname,
        "batchCount": "\(fullnames.count)",
        "requested": fullnames.prefix(12).joined(separator: ",")
      ]
    )

    Task {
      let datas = await RedditWire.shared.postData(forIDs: fullnames)
      let posts = Post.initMultiple(datas: datas, contentWidth: contentWidth)
      await MainActor.run {
        var hydrated = hydratedPosts
        for post in posts {
          if let data = post.data {
            for key in lookupKeys(fullname: data.name, postID: data.id) {
              hydrated[key] = post
            }
          }
        }
        hydratedPosts = hydrated
        hydratingFullnames.subtract(fullnames)
        AppDiagnostics.asyncRecord(
          posts.isEmpty ? .warning : .info,
          category: "savedLists.hydration",
          message: "Saved-list post batch hydrated",
          metadata: [
            "listID": listID.uuidString,
            "requested": "\(fullnames.count)",
            "recovered": "\(posts.count)",
            "recoveredIDs": posts.compactMap { $0.data?.name }.prefix(12).joined(separator: ",")
          ]
        )
      }
    }
  }

  private func hydratedPost(for item: SavedListItemSummary) -> Post? {
    for key in lookupKeys(fullname: item.fullname, postID: item.postID) {
      if let post = hydratedPosts[key] {
        return post
      }
    }
    return nil
  }

  private func lookupKeys(fullname: String, postID: String?) -> [String] {
    var keys: [String] = []
    func append(_ key: String?) {
      guard let key, !key.isEmpty, !keys.contains(key) else { return }
      keys.append(key)
    }
    append(fullname)
    append(fullname.trimmingCharacters(in: .whitespacesAndNewlines))
    if fullname.hasPrefix("t3_") {
      append(String(fullname.dropFirst(3)))
    } else {
      append("t3_\(fullname)")
    }
    if let postID {
      append(postID)
      append("t3_\(postID)")
    }
    return keys
  }
}

private struct SavedListItemRow: View {
  let item: SavedListItemSummary
  let rowWidth: CGFloat
  let hydratedPost: Post?
  let hydrate: () -> Void
  let remove: () -> Void
  let selectPost: (Post) -> Void
  let selectComment: (Comment) -> Void

  private let store = SavedListsStore.shared

  var body: some View {
    Group {
      switch item.kind {
      case .post:
        if let rowPost = hydratedPost ?? store.snapshotPost(from: item, contentWidth: rowWidth),
           let openPost = hydratedPost ?? store.openPost(from: item) {
          AuroraPostResultRow(post: rowPost, availableRowWidth: rowWidth) { _ in
            selectPost(openPost)
          }
          .contextMenu { menuItems(post: openPost, comment: nil) }
          .onAppear(perform: hydrate)
        }
      case .comment:
        if let comment = store.openComment(from: item) {
          AuroraCommentResultRow(comment: comment, select: selectComment)
            .contextMenu { menuItems(post: nil, comment: comment) }
        }
      }
    }
  }

  @ViewBuilder
  private func menuItems(post: Post?, comment: Comment?) -> some View {
    Button("Remove from List", systemImage: "trash", role: .destructive, action: remove)
    if let post {
      Button("Save...", systemImage: "bookmark") {
        SaveChooserInstance.shared.enable(.post(post))
      }
      Button {
        RenderingReportStore.shared.capturePostIssue(post: post, surface: "aurora-saved-list-row")
      } label: {
        Label("Report Rendering Issue", systemImage: "exclamationmark.bubble")
      }
    }
    if let comment {
      Button("Save...", systemImage: "bookmark") {
        SaveChooserInstance.shared.enable(.comment(comment))
      }
      Button {
        RenderingReportStore.shared.captureCommentIssue(comment: comment, surface: "aurora-saved-list-row")
      } label: {
        Label("Report Rendering Issue", systemImage: "exclamationmark.bubble")
      }
    }
  }
}

enum SavedListsRoute {
  static let overviewID = "saved-lists"
  static let listPrefix = "saved-list:"

  static func id(for listID: UUID) -> String {
    "\(listPrefix)\(listID.uuidString)"
  }

  static func listID(from selection: String?) -> UUID? {
    guard let selection, selection.hasPrefix(listPrefix) else { return nil }
    return UUID(uuidString: String(selection.dropFirst(listPrefix.count)))
  }
}
