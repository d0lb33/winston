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
  let listID: UUID
  let onPostSelected: (Post) -> Void
  let onCommentSelected: (Comment) -> Void

  @State private var list: SavedListSummary?
  @State private var items: [SavedListItemSummary] = []

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

  private func reload() {
    list = store.listSummary(id: listID)
    items = store.items(in: listID)
  }
}

private struct SavedListItemRow: View {
  let item: SavedListItemSummary
  let rowWidth: CGFloat
  let remove: () -> Void
  let selectPost: (Post) -> Void
  let selectComment: (Comment) -> Void

  private let store = SavedListsStore.shared

  var body: some View {
    Group {
      switch item.kind {
      case .post:
        if let post = store.openPost(from: item) {
          AuroraPostResultRow(post: post, availableRowWidth: rowWidth, select: selectPost)
            .contextMenu { menuItems(post: post, comment: nil) }
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
    }
    if let comment {
      Button("Save...", systemImage: "bookmark") {
        SaveChooserInstance.shared.enable(.comment(comment))
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
