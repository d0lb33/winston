//
//  BehaviorDefSettings.swift
//  winston
//
//  Created by Igor Marcossi on 15/12/23.
//

import Defaults

struct BehaviorDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  var openYoutubeApp: Bool = false
  var openLinksInApp: Bool = true
  var openRedditLinksFromClipboard: Bool = true
  var preferenceDefaultFeed: String = "subList"
  var doLiveText: Bool = true
  var iCloudSyncCredentials: Bool = true

  init(
    openYoutubeApp: Bool = false,
    openLinksInApp: Bool = true,
    openRedditLinksFromClipboard: Bool = true,
    preferenceDefaultFeed: String = "subList",
    doLiveText: Bool = true,
    iCloudSyncCredentials: Bool = true
  ) {
    self.openYoutubeApp = openYoutubeApp
    self.openLinksInApp = openLinksInApp
    self.openRedditLinksFromClipboard = openRedditLinksFromClipboard
    self.preferenceDefaultFeed = preferenceDefaultFeed
    self.doLiveText = doLiveText
    self.iCloudSyncCredentials = iCloudSyncCredentials
  }

  enum CodingKeys: String, CodingKey {
    case openYoutubeApp
    case openLinksInApp
    case openRedditLinksFromClipboard
    case preferenceDefaultFeed
    case doLiveText
    case iCloudSyncCredentials
  }

  init(from decoder: Decoder) throws {
    let fallback = BehaviorDefSettings()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    openYoutubeApp = try container.decodeIfPresent(Bool.self, forKey: .openYoutubeApp) ?? fallback.openYoutubeApp
    openLinksInApp = try container.decodeIfPresent(Bool.self, forKey: .openLinksInApp) ?? fallback.openLinksInApp
    openRedditLinksFromClipboard = try container.decodeIfPresent(Bool.self, forKey: .openRedditLinksFromClipboard) ?? fallback.openRedditLinksFromClipboard
    preferenceDefaultFeed = try container.decodeIfPresent(String.self, forKey: .preferenceDefaultFeed) ?? fallback.preferenceDefaultFeed
    doLiveText = try container.decodeIfPresent(Bool.self, forKey: .doLiveText) ?? fallback.doLiveText
    iCloudSyncCredentials = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncCredentials) ?? fallback.iCloudSyncCredentials
  }
}
