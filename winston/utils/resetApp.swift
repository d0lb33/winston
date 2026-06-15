//
//  resetApp.swift
//  winston
//
//  Created by Igor Marcossi on 04/09/23.
//

import Foundation
import Defaults
import CoreData

func resetApp() {
  resetCaches()
  resetCoreData()
  resetPreferences()
  resetCredentials()
}

func resetCredentials() {
  Task { @MainActor in
    for account in RedditWire.shared.accounts { await RedditWire.shared.removeAccount(account.id) }
  }
}

func resetPreferences() {
  UserDefaults.standard.removeAll()
}

func resetCaches() {
  Caches.ytPlayers.cache.removeAll()
  Caches.postsAttrStr.cache.removeAll()
  Caches.postsPreviewModels.cache.removeAll()
  Caches.avatars.cache.removeAll()
  Caches.videos.cache.removeAll()
}

func resetReadHistory() {
  deleteCoreDataEntity(named: "SeenPost")
}

func resetCoreData() {
  let container = PersistenceController.shared.container
  let entities = container.managedObjectModel.entities
  for entity in entities {
    deleteCoreDataEntity(named: entity.name!)
  }
}

private func deleteCoreDataEntity(named entityName: String) {
  let container = PersistenceController.shared.container
  let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
  let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
  do {
    _ = try container.viewContext.performAndWait {
      try container.viewContext.executeAndMergeChanges(deleteRequest)
//      try container.viewContext.save()
    }
  } catch let error as NSError {
    debugPrint(error)
  }
}
