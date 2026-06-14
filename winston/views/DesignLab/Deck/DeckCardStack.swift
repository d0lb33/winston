//
//  DeckCardStack.swift
//  winston
//
//  Design Lab · Deck — the compact browse experience: a horizontal, paging deck of
//  cards with depth (scale + 3D tilt on neighbours). Each card is a zoom-transition
//  source, so tapping it expands into the detail.
//

import SwiftUI

struct DeckCardStack: View {
  let posts: [MockPost]
  @Binding var focusedID: String?
  var namespace: Namespace.ID
  let onOpen: (MockPost) -> Void

  var body: some View {
    GeometryReader { geo in
      let cardWidth = geo.size.width * 0.84
      let sidePad = geo.size.width * 0.08

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(posts) { post in
            DeckCard(post: post, focused: focusedID == post.id, namespace: namespace)
              .frame(width: cardWidth)
              .matchedTransitionSource(id: post.id, in: namespace)
              .scrollTransition { content, phase in
                content
                  .scaleEffect(phase.isIdentity ? 1 : 0.9)
                  .opacity(phase.isIdentity ? 1 : 0.5)
                  .rotation3DEffect(.degrees(phase.value * -7), axis: (x: 0, y: 1, z: 0))
              }
              .onTapGesture { onOpen(post) }
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, sidePad)
        .padding(.vertical, 12)
      }
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $focusedID)
      .scrollClipDisabled()
    }
  }
}
