//
//  RedditTypes.swift
//  winston
//
//  Reddit data-shape primitives shared across the app. These predate the
//  GraphQL migration (they mirror Reddit's REST listing envelope) and survive
//  it because the entity models and the GraphQL adapters are built on them.
//

import Foundation
import Defaults

struct ListingChild<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: T?
}

struct Listing<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: ListingData<T>?
}

struct ListingData<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let after: String?
  let dist: Int?
  let modhash: String?
  let geo_filter: String?
  var children: [ListingChild<T>]?
}

enum Either<A: Codable & Hashable, B: Codable & Hashable>: Codable, Hashable {
  case first(A)
  case second(B)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    do {
      let firstType = try container.decode(A.self)
      self = .first(firstType)
    } catch let firstError {
      do {
        let secondType = try container.decode(B.self)
        self = .second(secondType)
      } catch let secondError {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Type mismatch for both types.", underlyingError: Swift.DecodingError.typeMismatch(Any.self, DecodingError.Context.init(codingPath: decoder.codingPath, debugDescription: "First type error: \(firstError). Second type error: \(secondError)")))
        throw DecodingError.dataCorrupted(context)
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .first(let value):
      try container.encode(value)
    case .second(let value):
      try container.encode(value)
    }
  }
}

enum VoteAction: String, Codable {
  case up = "1"
  case none = "0"
  case down = "-1"

  func boolVersion() -> Bool? {
    switch self {
    case .up:
      return true
    case .none:
      return nil
    case .down:
      return false
    }
  }
}

/// Subreddit link-flair template. Populated by the REST flair endpoint
/// historically; kept because SubredditData.winstonFlairs persists it.
/// TODO(graphql): no captured GraphQL operation lists subreddit link-flair
/// templates yet, so flair fetching is disabled.
struct Flair: GenericRedditEntityDataType, Identifiable, Defaults.Serializable {
      let type: String?
      let text_editable: Bool?
      let allowable_content: String?
      let text: String?
      let max_emojis: Int?
      let text_color: String?
      let mod_only: Bool?
      let css_class: String?
      let background_color: String?
      let id: String
}
