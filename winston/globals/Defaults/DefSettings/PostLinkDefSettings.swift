//
//  PostLinkSettings.swift
//  winston
//
//  Created by Igor Marcossi on 15/12/23.
//

import Foundation
import Defaults
import SwiftUI

enum HSide: String, Equatable, Codable, Hashable, Defaults.Serializable {
  case leading, trailing
}

enum VSide: String, Equatable, Codable, Hashable, Defaults.Serializable {
  case top, bottom
}

enum PostLinkDisplayStyle: String, CaseIterable, Identifiable, Equatable, Codable, Hashable, Defaults.Serializable {
  case clean, classic, compact

  var id: String { rawValue }

  var title: LocalizedStringResource {
    switch self {
    case .clean:
      "Clean"
    case .classic:
      "Classic"
    case .compact:
      "Compact"
    }
  }

  var detail: LocalizedStringResource {
    switch self {
    case .clean:
      "Metadata first, tighter spacing, full media."
    case .classic:
      "Original Winston post layout."
    case .compact:
      "Dense rows with side thumbnails."
    }
  }

  var systemImage: String {
    switch self {
    case .clean:
      "rectangle.split.1x2"
    case .classic:
      "doc.richtext"
    case .compact:
      "list.bullet.rectangle"
    }
  }
}

struct CompactPostLinkDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  var enabled: Bool = false
  var thumbnailSize: ThumbnailSizeModifier = .small
  var thumbnailSide: HSide = .trailing
  var voteButtonsSide: HSide = .trailing
  var showPlaceholderThumbnail: Bool = false
}

struct PostLinkDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  var postStyle: PostLinkDisplayStyle = .clean
  var compactMode: CompactPostLinkDefSettings = .init()
  var showAuthor: Bool = true
  var swipeActions: SwipeActionsSet = DEFAULT_POST_SWIPE_ACTIONS
  var showVotesCluster: Bool = true
  var showUpVoteRatio: Bool = false
  var blurNSFW: Bool = true
  var isMediaTappable: Bool = true
  var showSelfText: Bool = true
  var maxMediaHeightScreenPercentage: Double = 100
  var readOnScroll: Bool = false
  var lightboxReadsPost: Bool = false
  var hideOnRead: Bool = false

  var effectivePostStyle: PostLinkDisplayStyle {
    compactMode.enabled ? .compact : postStyle
  }

  func resolvedPostStyle(styleOverride: PostLinkDisplayStyle? = nil, compactOverride: Bool? = nil) -> PostLinkDisplayStyle {
    if let styleOverride { return styleOverride }
    guard let compactOverride else { return effectivePostStyle }
    return compactOverride ? .compact : (postStyle == .compact ? .classic : postStyle)
  }

  enum CodingKeys: String, CodingKey {
    case postStyle, compactMode, showAuthor, swipeActions, showVotesCluster, showUpVoteRatio, blurNSFW, isMediaTappable, showSelfText, maxMediaHeightScreenPercentage, readOnScroll, lightboxReadsPost, hideOnRead
  }

  init(
    postStyle: PostLinkDisplayStyle = .clean,
    compactMode: CompactPostLinkDefSettings = .init(),
    showAuthor: Bool = true,
    swipeActions: SwipeActionsSet = DEFAULT_POST_SWIPE_ACTIONS,
    showVotesCluster: Bool = true,
    showUpVoteRatio: Bool = false,
    blurNSFW: Bool = true,
    isMediaTappable: Bool = true,
    showSelfText: Bool = true,
    maxMediaHeightScreenPercentage: Double = 100,
    readOnScroll: Bool = false,
    lightboxReadsPost: Bool = false,
    hideOnRead: Bool = false
  ) {
    self.postStyle = postStyle
    self.compactMode = compactMode
    self.showAuthor = showAuthor
    self.swipeActions = swipeActions
    self.showVotesCluster = showVotesCluster
    self.showUpVoteRatio = showUpVoteRatio
    self.blurNSFW = blurNSFW
    self.isMediaTappable = isMediaTappable
    self.showSelfText = showSelfText
    self.maxMediaHeightScreenPercentage = maxMediaHeightScreenPercentage
    self.readOnScroll = readOnScroll
    self.lightboxReadsPost = lightboxReadsPost
    self.hideOnRead = hideOnRead
  }

  init(from decoder: Decoder) throws {
    let fallback = PostLinkDefSettings()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    postStyle = try container.decodeIfPresent(PostLinkDisplayStyle.self, forKey: .postStyle) ?? fallback.postStyle
    compactMode = try container.decodeIfPresent(CompactPostLinkDefSettings.self, forKey: .compactMode) ?? fallback.compactMode
    showAuthor = try container.decodeIfPresent(Bool.self, forKey: .showAuthor) ?? fallback.showAuthor
    swipeActions = try container.decodeIfPresent(SwipeActionsSet.self, forKey: .swipeActions) ?? fallback.swipeActions
    showVotesCluster = try container.decodeIfPresent(Bool.self, forKey: .showVotesCluster) ?? fallback.showVotesCluster
    showUpVoteRatio = try container.decodeIfPresent(Bool.self, forKey: .showUpVoteRatio) ?? fallback.showUpVoteRatio
    blurNSFW = try container.decodeIfPresent(Bool.self, forKey: .blurNSFW) ?? fallback.blurNSFW
    isMediaTappable = try container.decodeIfPresent(Bool.self, forKey: .isMediaTappable) ?? fallback.isMediaTappable
    showSelfText = try container.decodeIfPresent(Bool.self, forKey: .showSelfText) ?? fallback.showSelfText
    maxMediaHeightScreenPercentage = try container.decodeIfPresent(Double.self, forKey: .maxMediaHeightScreenPercentage) ?? fallback.maxMediaHeightScreenPercentage
    readOnScroll = try container.decodeIfPresent(Bool.self, forKey: .readOnScroll) ?? fallback.readOnScroll
    lightboxReadsPost = try container.decodeIfPresent(Bool.self, forKey: .lightboxReadsPost) ?? fallback.lightboxReadsPost
    hideOnRead = try container.decodeIfPresent(Bool.self, forKey: .hideOnRead) ?? fallback.hideOnRead
  }
}

//struct ModalsDefSettings: Hashable, Codable, Defaults.Serializable {
//  let showTestersCelebrationModal: Bool
//  let showTipJarModal: Bool
//}
