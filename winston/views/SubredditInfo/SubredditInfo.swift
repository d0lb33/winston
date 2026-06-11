//
//  SubredditInfo.swift
//  winston
//
//  Created by Igor Marcossi on 01/07/23.
//

import SwiftUI
import SwiftDate

enum SubInfoTabs: String, CaseIterable, Identifiable {
  var id: Self {
    return self
  }
  
  case info = "Info"
  case rules = "Rules"
  case myposts = "My posts"
}

struct SubredditInfo: View {
  @ObservedObject var subreddit: Subreddit

  @State private var selectedTab: SubInfoTabs = .info
  
  @StateObject private var myPosts = ObservableArray<Post>()
  @State private var myPostsLoaded = false
  @State private var isFavorited = false
  @Environment(\.useTheme) private var theme
  var body: some View {
    List {
      Group {
        if let data = subreddit.data {
          VStack(spacing: 12) {
            SubredditIcon(subredditIconKit: data.subredditIconKit, size: 125)
            
            VStack {
              Text("r/\(data.display_name ?? "")")
                .fontSize(22, .bold)
              Text("Created \(data.created == nil ? "at some point" : Date(timeIntervalSince1970: TimeInterval(data.created!)).toFormat("MMM dd, yyyy"))")
                .fontSize(16, .medium)
                .opacity(0.5)
              HStack{
                SubscribeButton(subreddit: subreddit)
                
              }
            }
            Picker("", selection: $selectedTab) {
              ForEach(SubInfoTabs.allCases) { tab in
                Text(tab.rawValue)
              }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
          }
          .id("header")
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
          .toolbar{
            ToolbarItem(){
              let remoteFavorited = data.user_has_favorited ?? false
              Button{
                withAnimation {
                  isFavorited.toggle()
                }
                subreddit.favoriteToggle()
              } label: {
                Label("Favorites", systemImage: isFavorited ? "star.fill" : "star")
                  .foregroundColor(.blue)
                  .labelStyle(.iconOnly)
              }
              .onAppear {
                isFavorited = remoteFavorited
              }
              .onChange(of: remoteFavorited) { favorited in
                withAnimation {
                  isFavorited = favorited
                }
              }
            }
          }
            
            switch selectedTab {
            case .info:
              SubredditInfoTab(subreddit: subreddit)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            case .myposts:
              SubredditMyPostsTab()
            case .rules:
              SubredditRulesTab(subreddit: subreddit)
            }
        }
      }
      .listRowSeparator(.hidden)
    }
    .themedListBG(theme.lists.bg)
    .navigationBarTitleDisplayMode(.inline)
  }
}
//
//struct SubredditInfo_Previews: PreviewProvider {
//    static var previews: some View {
//        SubredditInfo()
//    }
//}
