//
//  eraseAllEntriesOfEntity.swift
//  winston
//
//  Created by Igor Marcossi on 30/11/23.
//

import Foundation
import CoreData
import Defaults

func cleanCredentialOrphanEntities() {
  func clean(_ e: String) {
    let context = PersistenceController.shared.container.viewContext
    // Valid owners = legacy RedditCredentials + all connected GraphQL accounts.
    var validIDs = RedditCredentialsManager.shared.credentials.map { $0.id }
    validIDs.append(contentsOf: Defaults[.graphQLAccounts].map { $0.id })
    let predicates = validIDs.map { NSPredicate(format: "winstonCredentialID != %@", $0 as CVarArg)  }
    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: e)
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    do {
      _ = try context.performAndWait { try context.executeAndMergeChanges(deleteRequest) }
    } catch _ as NSError { }
  }
  PersistenceController.shared.container.viewContext.performAndWait {
    clean("CachedSub")
    clean("CachedMulti")
  }
}
