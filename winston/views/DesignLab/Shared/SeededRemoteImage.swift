//
//  SeededRemoteImage.swift
//  winston
//
//  Design Lab — a self-contained remote image for the mockups.
//
//  Loads a deterministic placeholder photo (seeded so it's stable per post) using the
//  iOS 27 `AsyncImage(request:)` initializer with HTTP caching, and falls back instantly
//  to a procedural gradient while loading or offline — so the demo never shows an empty
//  frame even with no network.
//

import SwiftUI

/// A shared, generously-sized image cache + session for every Design Lab `AsyncImage`.
/// Apply with `.designLabImageSession()` near each design's root.
enum DesignLabImageSession {
  static let shared: URLSession = {
    let config = URLSessionConfiguration.default
    config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    config.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: config)
  }()
}

extension View {
  /// Routes all `AsyncImage`s in the subtree through the Design Lab's cached session.
  func designLabImageSession() -> some View {
    self.asyncImageURLSession(DesignLabImageSession.shared)
  }
}

struct SeededRemoteImage: View {
  enum Service { case photo, avatar }

  let seed: String
  var service: Service = .photo
  var pixelWidth: Int = 800
  var pixelHeight: Int = 600
  var blurred: Bool = false        // NSFW / spoiler
  var showSymbol: Bool = true

  private var url: URL? {
    switch service {
    case .photo:
      return URL(string: "https://picsum.photos/seed/\(seed)/\(pixelWidth)/\(pixelHeight)")
    case .avatar:
      return URL(string: "https://i.pravatar.cc/\(max(pixelWidth, pixelHeight))?u=\(seed)")
    }
  }

  var body: some View {
    ZStack {
      // Always-present procedural base → never an empty frame, instant, offline-safe.
      MockMediaPalette.gradient(for: seed)
      if showSymbol {
        Image(systemName: MockMediaPalette.symbol(for: seed))
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white.opacity(0.22))
      }
      if let url {
        AsyncImage(
          request: URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad),
          transaction: Transaction(animation: .easeOut(duration: 0.35))
        ) { phase in
          if case .success(let image) = phase {
            image.resizable().scaledToFill()
          } else {
            Color.clear   // keep the gradient base visible while loading / on failure
          }
        }
      }
    }
    .clipped()
    .blur(radius: blurred ? 26 : 0)
  }
}
