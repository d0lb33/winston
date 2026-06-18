//
//  DesignLabGallery.swift
//  winston
//
//  Design Lab — the picker shown from Settings. Each concept opens full-screen so it
//  owns its entire navigation chrome; a glass close button returns here.
//

import SwiftUI

struct DesignLabGallery: View {
  @State private var presented: DesignLabConcept?

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        intro
        ForEach(DesignLabConcept.allCases) { concept in
          Button {
            presented = concept
          } label: {
            ConceptCard(concept: concept)
          }
          .buttonStyle(.plain)
        }

        Divider().padding(.vertical, 4)

        PostDetailConceptSection()
      }
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Design Lab")
    .navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(item: $presented) { concept in
      AuroraDesignLabPreview(theme: concept.auroraTheme) { presented = nil }
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("The Aurora family")
        .font(.title2.weight(.bold))
      Text("One UX built for foldables and iOS 27 — an adaptive three-pane glass split that folds down to a single column. Three moods to react to. All data is fake; explore freely.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Concept card

private struct ConceptCard: View {
  let concept: DesignLabConcept

  private var foreground: Color { concept.prefersDarkText ? Color(red: 0.16, green: 0.12, blue: 0.10) : .white }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        Image(systemName: concept.symbol)
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(foreground)
        Spacer()
        Label("Open", systemImage: "arrow.up.right")
          .font(.caption.weight(.bold))
          .padding(.horizontal, 11).padding(.vertical, 6)
          .background(foreground.opacity(0.16), in: .capsule)
          .foregroundStyle(foreground)
      }

      Spacer(minLength: 28)

      VStack(alignment: .leading, spacing: 6) {
        Text(concept.title)
          .font(.system(size: 30, weight: .heavy, design: concept.fontDesign))
          .foregroundStyle(foreground)
        Text(concept.tagline.uppercased())
          .font(.caption.weight(.semibold))
          .tracking(1.2)
          .foregroundStyle(foreground.opacity(0.7))
        Text(concept.blurb)
          .font(.subheadline)
          .foregroundStyle(foreground.opacity(0.86))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    .background(
      LinearGradient(colors: concept.galleryGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(.white.opacity(0.12), lineWidth: 0.7)
    )
    .shadow(color: concept.accent.opacity(0.28), radius: 18, x: 0, y: 10)
  }
}

#Preview("Gallery") {
  NavigationStack { DesignLabGallery() }
}
