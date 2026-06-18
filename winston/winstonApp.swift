//
//  winstonApp.swift
//  winston
//
//  Created by Igor Marcossi on 23/06/23.
//

import SwiftUI
import CoreData
import WhatsNewKit

var shortcutItemToProcess: UIApplicationShortcutItem?

enum AppQuickActions {
  private static func userInfo(name: String) -> [String: NSSecureCoding] {
    ["name": name as NSSecureCoding]
  }

  static func install() {
    UIApplication.shared.shortcutItems = [
      UIApplicationShortcutItem(
        type: "Search",
        localizedTitle: "Search",
        localizedSubtitle: "Search a Subreddit",
        icon: UIApplicationShortcutIcon(type: .search),
        userInfo: userInfo(name: "search")
      ),
      UIApplicationShortcutItem(
        type: "Saved",
        localizedTitle: "Saved",
        localizedSubtitle: "",
        icon: UIApplicationShortcutIcon(type: .bookmark),
        userInfo: userInfo(name: "saved")
      ),
    ]
  }
}

@main
struct winstonApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  let persistenceController = PersistenceController.shared
  
  var body: some Scene {
    WindowGroup {
      Group {
        if NavigationE2ELaunch.isEnabled {
          NavigationE2EHarnessView()
        } else if TapTargetE2ELaunch.isEnabled {
          TapTargetE2EHarnessView()
        } else {
          AppContent()
        }
      }
        .environment(\.managedObjectContext, persistenceController.container.viewContext)
        .environment(\.primaryBGContext, persistenceController.primaryBGContext)
        .environment(
          \.whatsNew,
           WhatsNewEnvironment(currentVersion: .current(), whatsNewCollection: getCurrentChangelog())
        )
        
    }
  }
}
