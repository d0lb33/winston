//
//  UserSavedLinks.swift
//  winston
//
//  Created by Ethan Bills on 11/16/23.
//

import Foundation
import SwiftUI
import Defaults

struct MixedContentFeedView: View {
  var mixedMediaLinks: [Either<Post, Comment>]
  @Binding var loadNextData: Bool
  
  weak var subreddit: Subreddit?
  @State private var loadingOverview = true
  @State private var lastItemId: String? = nil
  @Environment(\.useTheme) private var selectedTheme
  @Default(.PostLinkDefSettings) private var postLinkDefSettings
  @Default(.SubredditFeedDefSettings) private var subredditFeedDefSettings

  
  @State private var dataTypeFilter: String = "" // Handles filtering for only posts or only comments.
  
  @Binding var reachedEndOfFeed: Bool

//  @Environment(\.colorScheme) private var cs

  /// The inline-video gating key (post id) for a row, or nil if the row has no inline
  /// video. Matches the feedItemKey that PostLink threads into VideoPlayerPost.
  private func inlineVideoKey(for item: Either<Post, Comment>) -> String? {
    if case .first(let post) = item, post.winstonData?.extractedMedia?.isInlineVideo == true {
      return post.id
    }
    return nil
  }

  func updateContentsCalcs(_ newTheme: WinstonTheme) {
    Task(priority: .background) {
      mixedMediaLinks.forEach {
        switch $0 {
        case .first(let post):
          post.setupWinstonData(data: post.data, winstonData: post.winstonData, theme: newTheme, sub: subreddit, styleKey: subreddit?.id, fetchAvatar: false)
        case .second(let comment):
          comment.setupWinstonData()
          break
        }
      }
    }
  }
  
  var body: some View {
    let postLinksTheme = selectedTheme.postLinks
    let isThereDivider = selectedTheme.postLinks.divider.style != .no
    let paddingH = postLinksTheme.theme.outerHPadding
    let paddingV = postLinksTheme.spacing / (isThereDivider ? 4 : 2)
    
    List {
      Section {
        ForEach(Array(mixedMediaLinks.enumerated()), id: \.element.stableMixedContentID) { i, item in
          let inlineVideoKey = inlineVideoKey(for: item)
          MixedContentLink(content: item, theme: postLinksTheme)
          .trackInlineVideoCenter(key: inlineVideoKey ?? "", coordinateSpace: "mixedFeed", enabled: inlineVideoKey != nil)
          .listRowInsets(EdgeInsets(top: paddingV, leading: paddingH, bottom: paddingV, trailing: paddingH))
          .onAppear {
            if !reachedEndOfFeed && mixedMediaLinks.count > 0 && (Int(Double(mixedMediaLinks.count) * 0.75) == i) {
              loadNextData = true
            }
          }
          
          if selectedTheme.postLinks.divider.style != .no && i != (mixedMediaLinks.count - 1) {
            NiceDivider(divider: selectedTheme.postLinks.divider)
              .id("mixed-media-\(i)-divider")
              .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          }
        }
        
        if reachedEndOfFeed {
          EndOfFeedView()
        }
      }
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .environment(\.defaultMinListRowHeight, 1)
    }
//    .onChange(of: cs) { _ in updateContentsCalcs(selectedTheme) }
    .onChange(of: postLinkDefSettings) { updateContentsCalcs(selectedTheme) }
    .onChange(of: subredditFeedDefSettings.postStylePerSubreddit) { updateContentsCalcs(selectedTheme) }
    .onChange(of: selectedTheme) { _, newTheme in updateContentsCalcs(newTheme) }
    .themedListBG(selectedTheme.postLinks.bg)
    .scrollContentBackground(.hidden)
    .scrollIndicators(.never)
    .listStyle(.plain)
    .driveInlineVideoCoordinator(coordinateSpace: "mixedFeed")
  }
}

private extension Either where A == Post, B == Comment {
  var stableMixedContentID: String {
    getItemId(for: self)
  }
}
