//
//  SaveChooser.swift
//  winston
//

import SwiftUI

struct SaveChooserPresenter: ViewModifier {
  @ObservedObject private var shared = SaveChooserInstance.shared

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: Binding(get: { shared.isShowing == .post }, set: { if !$0 { shared.disable() } })) {
        SaveChooserSheet(subject: .post(shared.subjectPost))
      }
      .sheet(isPresented: Binding(get: { shared.isShowing == .comment }, set: { if !$0 { shared.disable() } })) {
        SaveChooserSheet(subject: .comment(shared.subjectComment))
      }
  }
}

extension View {
  func saveChooserPresenter() -> some View {
    modifier(SaveChooserPresenter())
  }
}

class SaveChooserInstance: ObservableObject {
  static let shared = SaveChooserInstance()
  private static let placeholderPost = Post.placeholder()
  private static let placeholderComment = Comment.placeholder()

  @Published private(set) var subjectPost: Post = SaveChooserInstance.placeholderPost
  @Published private(set) var subjectComment: Comment = SaveChooserInstance.placeholderComment
  @Published private(set) var isShowing: Showing = .none { didSet { if isShowing == .none { clearSubjects() } } }

  func enable(_ subject: Subject) {
    switch subject {
    case .post(let post):
      subjectPost = post
      doThisAfter(0.0) {
        withAnimation(spring) {
          self.isShowing = .post
        }
      }
    case .comment(let comment):
      subjectComment = comment
      doThisAfter(0.0) {
        withAnimation(spring) {
          self.isShowing = .comment
        }
      }
    }
  }

  func disable() {
    withAnimation(spring) { isShowing = .none }
    clearSubjects()
  }

  private func clearSubjects() {
    doThisAfter(0.4) {
      self.subjectPost = SaveChooserInstance.placeholderPost
      self.subjectComment = SaveChooserInstance.placeholderComment
    }
  }

  enum Subject {
    case post(Post)
    case comment(Comment)
  }

  enum Showing: String {
    case post
    case comment
    case none
  }
}

private enum SaveChooserSubject {
  case post(Post)
  case comment(Comment)

  var title: String {
    switch self {
    case .post(let post):
      return post.data?.title ?? "Post"
    case .comment(let comment):
      return comment.data?.link_title ?? comment.data?.body ?? "Comment"
    }
  }

  var savedToReddit: Bool {
    switch self {
    case .post(let post):
      return post.data?.saved == true
    case .comment(let comment):
      return comment.data?.saved == true
    }
  }

  var redditSaveLabel: String {
    savedToReddit ? "Unsave on Reddit" : "Save on Reddit"
  }

  var redditSaveIcon: String {
    savedToReddit ? "bookmark.slash" : "bookmark"
  }

  @MainActor
  func snapshot(store: SavedListsStore) -> SavedListItemSnapshot? {
    switch self {
    case .post(let post):
      return store.snapshot(for: post)
    case .comment(let comment):
      return store.snapshot(for: comment)
    }
  }

  func toggleRedditSave() async {
    switch self {
    case .post(let post):
      _ = await post.saveToggle()
    case .comment(let comment):
      _ = await comment.saveToggle()
    }
  }
}

private struct SaveChooserSheet: View {
  let subject: SaveChooserSubject

  @Environment(\.dismiss) private var dismiss
  @State private var recentLists: [SavedListSummary] = []
  @State private var containingLists: Set<UUID> = []
  @State private var newListName = ""
  @State private var showingAllLists = false
  @State private var savingReddit = false

  private let store = SavedListsStore.shared

  var body: some View {
    NavigationStack {
      List {
        SaveChooserRedditSection(
          savedToReddit: subject.savedToReddit,
          redditSaveLabel: subject.redditSaveLabel,
          redditSaveIcon: subject.redditSaveIcon,
          savingReddit: savingReddit,
          toggle: toggleRedditSave
        )

        SaveChooserRecentListsSection(
          lists: recentLists,
          containingLists: containingLists,
          toggle: toggleList
        )

        SaveChooserCreateListSection(
          newListName: $newListName,
          create: createList
        )

        Section {
          Button {
            showingAllLists = true
          } label: {
            Label("Save to List...", systemImage: "folder.badge.plus")
          }

          NavigationLink {
            SavedListsOverviewScreen(
              mode: .manage,
              onListSelected: { _ in }
            )
          } label: {
            Label("Manage Saved Lists", systemImage: "list.bullet.rectangle")
          }
        }
      }
      .navigationTitle("Save")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $showingAllLists) {
        NavigationStack {
          SavedListsOverviewScreen(mode: .picker, onListSelected: { list in
            toggleList(list)
            showingAllLists = false
          })
        }
      }
      .onAppear { reload() }
      .onReceive(NotificationCenter.default.publisher(for: .savedListsDidChange)) { _ in
        reload()
      }
    }
  }

  private func toggleRedditSave() {
    guard !savingReddit else { return }
    savingReddit = true
    Task {
      await subject.toggleRedditSave()
      await MainActor.run {
        savingReddit = false
      }
    }
  }

  private func toggleList(_ list: SavedListSummary) {
    guard let snapshot = subject.snapshot(store: store) else { return }
    _ = store.toggle(snapshot: snapshot, in: list.id)
    reload()
  }

  private func createList() {
    guard let list = store.createList(named: newListName) else { return }
    newListName = ""
    if let snapshot = subject.snapshot(store: store) {
      _ = store.add(snapshot: snapshot, to: list.id)
    }
    reload()
  }

  private func reload() {
    recentLists = store.recentLists()
    if let snapshot = subject.snapshot(store: store) {
      containingLists = store.listsContaining(fullname: snapshot.fullname)
    } else {
      containingLists = []
    }
  }
}

private struct SaveChooserRedditSection: View {
  let savedToReddit: Bool
  let redditSaveLabel: String
  let redditSaveIcon: String
  let savingReddit: Bool
  let toggle: () -> Void

  var body: some View {
    Section("Reddit") {
      Button(action: toggle) {
        HStack {
          Label(redditSaveLabel, systemImage: redditSaveIcon)
          Spacer()
          if savingReddit {
            ProgressView()
              .controlSize(.small)
          } else if savedToReddit {
            Image(systemName: "checkmark")
              .foregroundStyle(.green)
          }
        }
      }
    }
  }
}

private struct SaveChooserRecentListsSection: View {
  let lists: [SavedListSummary]
  let containingLists: Set<UUID>
  let toggle: (SavedListSummary) -> Void

  var body: some View {
    Section("Recent Lists") {
      if lists.isEmpty {
        ContentUnavailableView("No lists yet", systemImage: "list.bullet")
          .frame(maxWidth: .infinity)
      } else {
        ForEach(lists) { list in
          Button {
            toggle(list)
          } label: {
            SaveChooserListRow(
              name: list.name,
              count: list.count,
              selected: containingLists.contains(list.id)
            )
          }
        }
      }
    }
  }
}

private struct SaveChooserCreateListSection: View {
  @Binding var newListName: String
  let create: () -> Void

  var body: some View {
    Section("New List") {
      HStack {
        TextField("List name", text: $newListName)
          .textInputAutocapitalization(.words)
        Button("Create", action: create)
          .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }
}

private struct SaveChooserListRow: View {
  let name: String
  let count: Int
  let selected: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: selected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(selected ? .green : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.primary)
        Text("\(count) items")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
}
