//
//  observableArray.swift
//  winston
//
//  Created by Igor Marcossi on 06/07/23.
//

import Foundation
import Combine

@MainActor
class ObservableArray<T: ObservableObject>: ObservableObject {
  @Published var data:[T] = [] {
    didSet { observeChildrenChanges() }
  }
  var cancellables = [AnyCancellable]()
  
  init(array: [T]? = nil) {
    if let array = array {
      self.data = array
    }
    self.observeChildrenChanges()
  }
  
  func observeChildrenChanges() {
    cancellables.forEach { cancelable in
      cancelable.cancel()
    }
    cancellables.removeAll()
    // `[weak self]` is REQUIRED: the sink's AnyCancellable is stored in `self.cancellables`,
    // and the closure captures self — a strong capture is a retain cycle, so the
    // ObservableArray (and everything it holds: the whole comment tree, the post header's
    // AVPlayer, etc.) would never deinit. Leaking an AVPlayer per post visit accumulates
    // media-decoder resources across a session → escalating hangs / watchdog kills.
    data.forEach({
      self.cancellables.append($0.objectWillChange.sink(receiveValue: { [weak self] _ in
        self?.objectWillChange.send()
      }))
      if let comment = $0 as? GenericRedditEntity<CommentData, CommentWinstonData>, let wd = comment.winstonData {
        self.cancellables.append(wd.objectWillChange.sink(receiveValue: { [weak self] _ in self?.objectWillChange.send() }))
      }
    })
  }
}

@MainActor
class NonObservableArray<T: ObservableObject>: ObservableObject {
  @Published var data:[T] = []
}
