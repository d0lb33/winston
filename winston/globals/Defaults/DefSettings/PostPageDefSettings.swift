//
//  PostPageDefSettings.swift
//  winston
//
//  Created by Igor Marcossi on 15/12/23.
//

import Defaults

struct PostPageDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  var blurNSFW: Bool = false
  var preferredSearchSort: SubListingSortOption = .best
  var perPostSort: Bool = false
  var postSorts: Dictionary<String, CommentSortOption> = .init()
  var showUpVoteRatio: Bool = true
  /// The iOS 27 native post + comments screen (PostViewNative) is the default
  /// viewing experience. Users can turn this off (Settings → Behavior → Comments)
  /// to fall back to the legacy PostView path.
  var useNativeCommentsView: Bool = true
}
