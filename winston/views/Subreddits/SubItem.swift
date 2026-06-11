//
//  SubItem.swift
//  winston
//
//  Created by Igor Marcossi on 05/08/23.
//

import SwiftUI

struct SubItemButton: View, Equatable {
  static func == (lhs: SubItemButton, rhs: SubItemButton) -> Bool {
    lhs.data == rhs.data
  }
  
  var data: SubredditData
  var action: () -> ()
  var body: some View {
    Button(action: action) {
        HStack {
          Text(data.display_name ?? "")
          SubredditIcon(subredditIconKit: data.subredditIconKit)
        }
      }
  }
}

struct SubItem: View {
  var isActive: Bool
  var selectSub: (Subreddit) -> ()
  @ObservedObject var sub: Subreddit
  @ObservedObject var cachedSub: CachedSub
  var onFavoriteChanged: ((Bool) -> ())?
  @State private var isFavorited: Bool

  init(isActive: Bool, selectSub: @escaping (Subreddit) -> (), sub: Subreddit, cachedSub: CachedSub, onFavoriteChanged: ((Bool) -> ())? = nil) {
    self.isActive = isActive
    self.selectSub = selectSub
    self._sub = ObservedObject(wrappedValue: sub)
    self._cachedSub = ObservedObject(wrappedValue: cachedSub)
    self.onFavoriteChanged = onFavoriteChanged
    self._isFavorited = State(initialValue: cachedSub.user_has_favorited)
  }
  
  func favoriteToggle() {
    withAnimation {
      isFavorited.toggle()
    }
    onFavoriteChanged?(isFavorited)
    sub.favoriteToggle(entity: cachedSub, onStateChange: onFavoriteChanged)
  }
  
  var body: some View {
    if let data = sub.data {
//      let isActive = selectedSub == .reddit(.subFeed(sub))
      WListButton(showArrow: !IPAD, active: isActive) {
        selectSub(sub)
      } label: {
        HStack {
          Label {
            Text(data.display_name ?? "")
              .foregroundStyle(isActive ? .white : .primary)
          } icon: {
            SubredditIcon(subredditIconKit: data.subredditIconKit)
          }
          
          Spacer()
          
          Image(systemName: "star.fill")
            .foregroundColor(isFavorited ? Color.accentColor : .gray.opacity(0.3))
            .highPriorityGesture( TapGesture().onEnded(favoriteToggle) )
        }
      }
      .onAppear {
        isFavorited = cachedSub.user_has_favorited
      }
      .onChange(of: cachedSub.user_has_favorited) { favorited in
        withAnimation {
          isFavorited = favorited
        }
      }
      
    } else {
      Text("Error")
    }
  }
}
