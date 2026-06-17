//
//  Me.swift
//  winston
//
//  Created by Igor Marcossi on 24/06/23.
//

import SwiftUI

struct Me: View {
  let nav: ColumnNav
  @ObservedObject var wire = RedditWire.shared
  
  @State private var loading = true
  var body: some View {
    RedditTwoColumnShell(nav: nav) { _ in
      Group {
        if let user = wire.me {
          UserView(user: user)
            .id("me-user-view-\(user.id)")
          
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .frame(maxWidth: .infinity, minHeight: 320)
            .onAppear {
              Task(priority: .background) {
                await RedditWire.shared.fetchMe(force: true)
              }
            }
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          AccountSwitcherTrigger(onTap: {}) {
            Image(systemName: "person.2.fill")
              .font(.body.weight(.semibold))
              .foregroundStyle(.primary)
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Switch account")
        }
      }
    }
  }
}

//struct Me_Previews: PreviewProvider {
//  static var previews: some View {
//    Me()
//  }
//}
