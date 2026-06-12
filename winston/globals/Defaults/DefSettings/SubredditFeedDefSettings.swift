//
//  SubredditFeedDefSettings.swift
//  winston
//
//  Created by Igor Marcossi on 15/12/23.
//

import Defaults

struct SubredditFeedDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  var preferredSort: SubListingSortOption = .best
  var preferredSearchSort: SubListingSortOption = .best
  var compactPerSubreddit: Dictionary<String, Bool> = .init()
  var postStylePerSubreddit: Dictionary<String, PostLinkDisplayStyle> = .init()
  var chunkLoadSize: Int = 25
  var perSubredditSort: Bool = false
  var openOptionsOnTap: Bool = false
  var subredditSorts: Dictionary<String, SubListingSortOption> = .init()

  enum CodingKeys: String, CodingKey {
    case preferredSort, preferredSearchSort, compactPerSubreddit, postStylePerSubreddit, chunkLoadSize, perSubredditSort, openOptionsOnTap, subredditSorts
  }

  init(
    preferredSort: SubListingSortOption = .best,
    preferredSearchSort: SubListingSortOption = .best,
    compactPerSubreddit: Dictionary<String, Bool> = .init(),
    postStylePerSubreddit: Dictionary<String, PostLinkDisplayStyle> = .init(),
    chunkLoadSize: Int = 25,
    perSubredditSort: Bool = false,
    openOptionsOnTap: Bool = false,
    subredditSorts: Dictionary<String, SubListingSortOption> = .init()
  ) {
    self.preferredSort = preferredSort
    self.preferredSearchSort = preferredSearchSort
    self.compactPerSubreddit = compactPerSubreddit
    self.postStylePerSubreddit = postStylePerSubreddit
    self.chunkLoadSize = chunkLoadSize
    self.perSubredditSort = perSubredditSort
    self.openOptionsOnTap = openOptionsOnTap
    self.subredditSorts = subredditSorts
  }

  init(from decoder: Decoder) throws {
    let fallback = SubredditFeedDefSettings()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    preferredSort = try container.decodeIfPresent(SubListingSortOption.self, forKey: .preferredSort) ?? fallback.preferredSort
    preferredSearchSort = try container.decodeIfPresent(SubListingSortOption.self, forKey: .preferredSearchSort) ?? fallback.preferredSearchSort
    compactPerSubreddit = try container.decodeIfPresent(Dictionary<String, Bool>.self, forKey: .compactPerSubreddit) ?? fallback.compactPerSubreddit
    postStylePerSubreddit = try container.decodeIfPresent(Dictionary<String, PostLinkDisplayStyle>.self, forKey: .postStylePerSubreddit) ?? fallback.postStylePerSubreddit
    chunkLoadSize = try container.decodeIfPresent(Int.self, forKey: .chunkLoadSize) ?? fallback.chunkLoadSize
    perSubredditSort = try container.decodeIfPresent(Bool.self, forKey: .perSubredditSort) ?? fallback.perSubredditSort
    openOptionsOnTap = try container.decodeIfPresent(Bool.self, forKey: .openOptionsOnTap) ?? fallback.openOptionsOnTap
    subredditSorts = try container.decodeIfPresent(Dictionary<String, SubListingSortOption>.self, forKey: .subredditSorts) ?? fallback.subredditSorts
  }
}
