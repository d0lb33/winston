//
//  PreviewModel.swift
//  winston
//
//  Created by Igor Marcossi on 26/09/23.
//

import Foundation
import SwiftUI
import OpenGraph
import NukeUI
import Defaults

struct PreviewModelState: Equatable {
  var image: String?
  var title: String?
  var url: URL?
  var description: String?
  var loading = true
}

final class PreviewModel: ObservableObject, Equatable {
  static func == (lhs: PreviewModel, rhs: PreviewModel) -> Bool {
    lhs.state.url == rhs.state.url
  }
  
  @Published private(set) var state = PreviewModelState()
  
  var previewURL: URL?
  
  init() {}
  
  init(_ url: URL, compact: Bool) {
    self.previewURL = url
    fetchMetadata(compact: compact)
  }
  
  static func get(_ url: URL, compact: Bool) -> PreviewModel {
    if let previewModel = Caches.postsPreviewModels.get(key: url.absoluteString) {
      return previewModel
    } else {
      let previewModel = PreviewModel(url, compact: compact)
      Caches.postsPreviewModels.addKeyValue(key: url.absoluteString, data: { previewModel })
      
      return previewModel
    }
  }
  
  private func fetchMetadata(compact: Bool) {
    guard let previewURL else { return }
    
    Task(priority: .background) {
      var headers = [String: String]()
      headers["User-Agent"] = "facebookexternalhit/1.1"
      headers["charset"] = "UTF-8"
      if let og = try? await OpenGraph.fetch(url: previewURL, headers: headers) {
        let image = og[.image]?.escape
        if let image, let imgURL = URL(string: image) {
          let imageSize = compact ? scaledCompactModeThumbSize(compact: compact) : 76
          await MainActor.run {
            Post.prefetcher.startPrefetching(with: [ImageRequest(url: imgURL, processors: [.resize(size: CGSize(width: imageSize, height: imageSize))], priority: .veryLow)])
          }
        }
        await MainActor.run {
          state = PreviewModelState(
            image: image,
            title: og[.title]?.escape,
            url: URL(string: og[.url]?.escape ?? ""),
            description: og[.description]?.escape,
            loading: false
          )
        }
      } else {
        await MainActor.run {
          state = PreviewModelState(loading: false)
        }
      }
    }
  }
}
