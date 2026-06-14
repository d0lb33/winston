//
//  DesignLabConcept.swift
//  winston
//
//  Design Lab — the three design concepts surfaced in the gallery.
//

import SwiftUI

enum DesignLabConcept: String, Identifiable, CaseIterable {
  case aurora, press, deck

  var id: String { rawValue }

  var title: String {
    switch self {
    case .aurora: "Aurora"
    case .press:  "Press"
    case .deck:   "Deck"
    }
  }

  var tagline: String {
    switch self {
    case .aurora: "Liquid Glass · adaptive split"
    case .press:  "Editorial · the daily read"
    case .deck:   "Spatial · swipe the deck"
    }
  }

  var blurb: String {
    switch self {
    case .aurora: "Translucent glass panes float over a living gradient. Unfold to reveal subreddits, feed and conversation side by side."
    case .press:  "A magazine for your feed. A serif cover story, a masonry of stories, and a calm reading column for comments."
    case .deck:   "Flick through posts like a deck of cards. Tap to zoom in, drag the comments up. Unfold to browse and read at once."
    }
  }

  var symbol: String {
    switch self {
    case .aurora: "sparkles.rectangle.stack.fill"
    case .press:  "newspaper.fill"
    case .deck:   "rectangle.portrait.on.rectangle.portrait.angled.fill"
    }
  }

  /// Signature accent for the gallery card. Each design defines its own internal palette too.
  var accent: Color {
    switch self {
    case .aurora: Color(red: 0.36, green: 0.78, blue: 0.98)   // glacial cyan
    case .press:  Color(red: 0.85, green: 0.26, blue: 0.18)   // vermillion ink
    case .deck:   Color(red: 0.62, green: 0.94, blue: 0.27)   // electric lime
    }
  }

  var galleryGradient: [Color] {
    switch self {
    case .aurora: [Color(red: 0.13, green: 0.20, blue: 0.40), Color(red: 0.20, green: 0.52, blue: 0.66), Color(red: 0.42, green: 0.30, blue: 0.62)]
    case .press:  [Color(red: 0.96, green: 0.94, blue: 0.89), Color(red: 0.90, green: 0.86, blue: 0.78)]
    case .deck:   [Color(red: 0.06, green: 0.06, blue: 0.09), Color(red: 0.14, green: 0.16, blue: 0.10)]
    }
  }
}
