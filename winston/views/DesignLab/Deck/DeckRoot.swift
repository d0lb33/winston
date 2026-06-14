//
//  DeckRoot.swift
//  winston
//
//  Design Lab · Deck — spatial, swipe the deck.
//
//  Navigation system: a horizontal paging deck of cards. Tapping a card uses the iOS 27
//  zoom transition to expand into the detail (compact). When wide (fold open), it splits
//  into a browse column + an open post & comments column — browse without losing your
//  place. Communities switch via a pull-down command palette.
//

import SwiftUI

struct DeckRoot: View {
  var onClose: () -> Void = {}

  @State private var selectedSubID: String? = nil
  @State private var focusedID: String? = nil
  @State private var selectedPostID: String? = nil
  @State private var path: [String] = []
  @State private var showPalette = false
  @Namespace private var deckNS
  @Environment(\.horizontalSizeClass) private var hSize

  private var wide: Bool { hSize == .regular }
  private var posts: [MockPost] { MockData.posts(in: selectedSubID) }
  private var sectionTitle: String {
    guard let id = selectedSubID else { return "Popular" }
    return MockData.subreddits.first { $0.id == id }?.displayName ?? "Popular"
  }
  private var selectedPost: MockPost? {
    guard let selectedPostID else { return nil }
    return MockData.feed.first { $0.id == selectedPostID }
  }

  var body: some View {
    ZStack {
      DeckPalette.canvas.ignoresSafeArea()

      if wide { wideLayout } else { compactLayout }

      if showPalette {
        DeckCommandPalette(selectedSubID: $selectedSubID, isPresented: $showPalette)
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(5)
      }
    }
    .preferredColorScheme(.dark)
    .tint(DeckPalette.accent)
    .designLabImageSession()
    .onAppear {
      if focusedID == nil { focusedID = posts.first?.id }
      if wide && selectedPostID == nil { selectedPostID = posts.first?.id }
    }
    .onChange(of: selectedSubID) { _, _ in
      withAnimation(.snappy) {
        path.removeAll()
        focusedID = posts.first?.id
        selectedPostID = wide ? posts.first?.id : nil
      }
    }
  }

  // MARK: Compact — paging deck + zoom into detail

  private var compactLayout: some View {
    NavigationStack(path: $path) {
      DeckCardStack(posts: posts, focusedID: $focusedID, namespace: deckNS) { post in
        path.append(post.id)
      }
      .safeAreaInset(edge: .top) { topBar }
      .background(DeckPalette.canvas)
      .navigationDestination(for: String.self) { id in
        if let post = MockData.feed.first(where: { $0.id == id }) {
          DeckPostDetail(post: post, useSheet: true, onBack: { if !path.isEmpty { path.removeLast() } })
            .navigationTransition(.zoom(sourceID: id, in: deckNS))
        }
      }
      .toolbar(.hidden, for: .navigationBar)
    }
  }

  // MARK: Wide — browse column + detail column

  private var wideLayout: some View {
    HStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(posts) { post in
            DeckCard(post: post, focused: selectedPostID == post.id, namespace: deckNS, compact: true)
              .frame(height: 150)
              .onTapGesture { withAnimation(.snappy) { selectedPostID = post.id } }
          }
        }
        .padding(16)
      }
      .frame(width: 360)
      .background(DeckPalette.canvas)

      Rectangle().fill(.white.opacity(0.06)).frame(width: 1)

      Group {
        if let post = selectedPost {
          DeckPostDetail(post: post, useSheet: false)
            .id(post.id)
            .transition(.opacity)
        } else {
          DeckEmptyDetail()
        }
      }
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .top) { topBar }
  }

  // MARK: Shared top bar

  private var topBar: some View {
    HStack(spacing: 12) {
      Button { withAnimation(.snappy) { showPalette = true } } label: {
        HStack(spacing: 7) {
          Image(systemName: "square.stack.3d.up.fill")
          Text(sectionTitle).font(.subheadline.weight(.bold))
          Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
      .buttonStyle(SpringButtonStyle())
      Spacer()
      DesignLabClose(tint: .white, action: onClose)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

struct DeckEmptyDetail: View {
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "hand.tap.fill")
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(DeckPalette.accent)
      Text("Tap a card").font(.title3.weight(.bold)).foregroundStyle(.white)
      Text("Open a post here and keep flicking through the deck on the left.")
        .font(.subheadline).foregroundStyle(.white.opacity(0.6))
        .multilineTextAlignment(.center).frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DeckPalette.canvas)
  }
}

#Preview("Deck") {
  DeckRoot()
}
