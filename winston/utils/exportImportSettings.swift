//
//  exportImportSettings.swift
//  winston
//
//  Created by Daniel Inama on 19/10/23.
//

import Foundation
import Zip

func exportUserDefaultsToJSON(fileName: String) -> String? {
  // Get all UserDefaults keys and values as a dictionary
  let userDefaults = UserDefaults.standard
  let userDefaultsDictionary = userDefaults.dictionaryRepresentation()
  
  // Create a dictionary to hold the serialized values
  var serializedDictionary: [String: Any] = [:]
  
  for (key, value) in userDefaultsDictionary {
    if let date = value as? Date {
      // Convert Date to a string representation
      serializedDictionary[key] = date.iso8601String
    } else {
      // For other types, use the value as is
      serializedDictionary[key] = value
    }
  }
  
  do {
    // Serialize the modified dictionary as JSON data
    let jsonData = try JSONSerialization.data(withJSONObject: serializedDictionary, options: .prettyPrinted)
    
    // Define the file URL where you want to save the JSON file
    if let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      let fileURL = documentsDirectory.appendingPathComponent(fileName)
      
      // Write the JSON data to the file
      try jsonData.write(to: fileURL)
      
      print("UserDefaults exported to: \(fileURL.absoluteString)")
      return fileURL.absoluteString
    }
  } catch {
    print("Error exporting UserDefaults to JSON: \(error)")
  }
  
  return nil
}

func importUserDefaultsFromJSON(jsonFilePath: URL) -> Bool {
  // Check if the file exists at the provided path
  let gotAccess = jsonFilePath.startAccessingSecurityScopedResource()
  if !gotAccess {
    print("Can't get file access")
    return false
  }
  do {
    // Read the JSON data from the file
    let jsonData = try Data(contentsOf:jsonFilePath)
    
    // Deserialize the JSON data into a dictionary
    if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
      // Iterate through the dictionary and set the values in UserDefaults
      for (key, value) in jsonObject {
        if let dateStr = value as? String,
           let date = Date.dateFromISO8601String(dateStr) {
          UserDefaults.standard.set(date, forKey: key)
        } else {
          UserDefaults.standard.set(value, forKey: key)
        }
      }
      
      // Synchronize UserDefaults to save the changes
      UserDefaults.standard.synchronize()
      
      print("UserDefaults imported from: \(jsonFilePath)")
      jsonFilePath.stopAccessingSecurityScopedResource()
      return true
    }
  } catch {
    print("Error importing UserDefaults from JSON: \(error)")
    jsonFilePath.stopAccessingSecurityScopedResource()
  }
  return false
}

struct ApolloReadHistoryParseResult: Equatable {
  let rawCount: Int
  let postIDs: [String]
  let invalidCount: Int

  var validUniqueCount: Int { postIDs.count }
}

enum ApolloReadHistoryImportError: LocalizedError {
  case preferencesPlistNotFound
  case unreadablePreferencesPlist
  case missingReadPostIDs
  case invalidReadPostIDs
  case unsupportedBackupFile

  var errorDescription: String? {
    switch self {
    case .preferencesPlistNotFound:
      return "Could not find preferences.plist in this Apollo backup."
    case .unreadablePreferencesPlist:
      return "Could not read Apollo preferences.plist."
    case .missingReadPostIDs:
      return "This Apollo backup does not contain ReadPostIDs."
    case .invalidReadPostIDs:
      return "ReadPostIDs was not in the expected format."
    case .unsupportedBackupFile:
      return "Choose an Apollo .zip backup or preferences.plist file."
    }
  }
}

enum ApolloReadHistoryImporter {
  static func readPostIDs(fromBackupURL url: URL) throws -> ApolloReadHistoryParseResult {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let fileName = url.lastPathComponent.lowercased()
    if fileName == "preferences.plist" || url.pathExtension.lowercased() == "plist" {
      return try parseReadPostIDs(fromPreferencesData: Data(contentsOf: url))
    }

    guard url.pathExtension.lowercased() == "zip" else {
      throw ApolloReadHistoryImportError.unsupportedBackupFile
    }

    return try readPostIDs(fromZipURL: url)
  }

  static func parseReadPostIDs(fromPreferencesData data: Data) throws -> ApolloReadHistoryParseResult {
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dictionary = plist as? [String: Any] else {
      throw ApolloReadHistoryImportError.unreadablePreferencesPlist
    }
    guard let rawIDs = dictionary["ReadPostIDs"] else {
      throw ApolloReadHistoryImportError.missingReadPostIDs
    }
    guard let rawIDs = rawIDs as? [String] else {
      throw ApolloReadHistoryImportError.invalidReadPostIDs
    }

    var seenIDs = Set<String>()
    var postIDs: [String] = []
    var invalidCount = 0

    for rawID in rawIDs {
      guard let postID = normalizedReadPostID(rawID) else {
        invalidCount += 1
        continue
      }

      if seenIDs.insert(postID).inserted {
        postIDs.append(postID)
      }
    }

    return ApolloReadHistoryParseResult(
      rawCount: rawIDs.count,
      postIDs: postIDs,
      invalidCount: invalidCount
    )
  }

  static func normalizedReadPostID(_ rawID: String) -> String? {
    var postID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if postID.hasPrefix("t3_") {
      postID.removeFirst(3)
    }
    while postID.hasPrefix("_") {
      postID.removeFirst()
    }
    guard !postID.isEmpty else { return nil }
    guard postID.unicodeScalars.allSatisfy(isASCIIAlphaNumeric) else { return nil }
    return postID
  }

  private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
  }

  private static func readPostIDs(fromZipURL url: URL) throws -> ApolloReadHistoryParseResult {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory
      .appendingPathComponent("ApolloReadHistoryImport-\(UUID().uuidString)", isDirectory: true)
    let zipCopyURL = tempRoot.appendingPathComponent(url.lastPathComponent)
    let unzipDestination = tempRoot.appendingPathComponent("unzipped", isDirectory: true)

    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: tempRoot)
    }

    try fileManager.copyItem(at: url, to: zipCopyURL)
    try fileManager.createDirectory(at: unzipDestination, withIntermediateDirectories: true)
    try Zip.unzipFile(zipCopyURL, destination: unzipDestination, overwrite: true, password: nil)

    guard let preferencesURL = preferencesPlistURL(in: unzipDestination) else {
      throw ApolloReadHistoryImportError.preferencesPlistNotFound
    }

    return try parseReadPostIDs(fromPreferencesData: Data(contentsOf: preferencesURL))
  }

  private static func preferencesPlistURL(in directory: URL) -> URL? {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return nil }

    for case let fileURL as URL in enumerator {
      if fileURL.lastPathComponent == "preferences.plist" {
        return fileURL
      }
    }

    return nil
  }
}

// Extension to convert Date to ISO8601 string
extension Date {
  var iso8601String: String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: self)
  }
}

// Extension to convert ISO8601 string to Date
extension Date {
  static func dateFromISO8601String(_ iso8601String: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: iso8601String)
  }
}
