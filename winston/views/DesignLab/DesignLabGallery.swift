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

  /// Concepts that are fully built. Others render as "in progress" until they land.
  private let available: Set<DesignLabConcept> = [.aurora, .press, .deck]

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        intro
        ForEach(DesignLabConcept.allCases) { concept in
          Button {
            presented = concept
          } label: {
            ConceptCard(concept: concept, available: available.contains(concept))
          }
          .buttonStyle(.plain)
          .disabled(!available.contains(concept))
        }
      }
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Design Lab")
    .navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(item: $presented) { concept in
      DesignLabHost(concept: concept) { presented = nil }
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Three ways to read Reddit")
        .font(.title2.weight(.bold))
      Text("Mockups built for foldables and iOS 27. Each has its own navigation and adapts as the screen folds, unfolds and resizes. All data is fake — explore freely.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Concept card

private struct ConceptCard: View {
  let concept: DesignLabConcept
  let available: Bool

  private var foreground: Color { concept == .press ? Color(red: 0.16, green: 0.12, blue: 0.10) : .white }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        Image(systemName: concept.symbol)
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(foreground)
        Spacer()
        if available {
          Label("Open", systemImage: "arrow.up.right")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(foreground.opacity(0.16), in: .capsule)
            .foregroundStyle(foreground)
        } else {
          Text("In progress")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(foreground.opacity(0.16), in: .capsule)
            .foregroundStyle(foreground.opacity(0.8))
        }
      }

      Spacer(minLength: 28)

      VStack(alignment: .leading, spacing: 6) {
        Text(concept.title)
          .font(.system(size: 30, weight: .heavy, design: concept == .press ? .serif : .rounded))
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
    .opacity(available ? 1 : 0.92)
  }
}

// MARK: - Full-screen host

/// Routes a chosen concept to its self-contained root. Each root owns its own nav chrome.
struct DesignLabHost: View {
  let concept: DesignLabConcept
  let onClose: () -> Void

  var body: some View {
    switch concept {
    case .aurora:
      AuroraRoot(onClose: onClose)
    case .press:
      PressRoot(onClose: onClose)
    case .deck:
      DeckRoot(onClose: onClose)
    }
  }
}

// MARK: - Placeholder for concepts still under construction

struct DesignLabComingSoon: View {
  let concept: DesignLabConcept
  let onClose: () -> Void

  var body: some View {
    ZStack {
      LinearGradient(colors: concept.galleryGradient, startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
      VStack(spacing: 12) {
        Image(systemName: concept.symbol).font(.system(size: 52, weight: .light))
        Text(concept.title).font(.system(size: 34, weight: .heavy, design: .rounded))
        Text("Coming soon").font(.headline).opacity(0.8)
      }
      .foregroundStyle(concept == .press ? Color.black : Color.white)
    }
    .overlay(alignment: .topTrailing) {
      DesignLabClose(tint: concept == .press ? .black : .white, action: onClose)
        .padding(.top, 8).padding(.trailing, 14)
    }
  }
}

#Preview("Gallery") {
  NavigationStack { DesignLabGallery() }
}
