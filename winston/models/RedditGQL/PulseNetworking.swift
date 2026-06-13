//
//  PulseNetworking.swift
//  winston
//
//  Central Pulse wiring: an HTTPTransport that mirrors every RedditPOC request
//  into the Pulse store (Settings → Diagnostics → Network Console), with
//  Reddit credential material scrubbed before anything is persisted.
//
//  We log directly from the transport (rather than via URLSessionProxyDelegate)
//  because RedditPOC issues requests with the async `URLSession.data(for:)`
//  convenience, which never surfaces the response body or completion to a
//  session delegate — the proxy path captured task creation only, leaving
//  every request stuck on "Pending" with no status or body.
//

import Foundation
import Pulse
import RedditPOC

enum PulseNetworking {
  /// Header names whose values are replaced before storage. Matched
  /// case-insensitively; entries ending in `*` match by prefix.
  private static let sensitiveHeaderPatterns = [
    "authorization",
    "cookie",
    "set-cookie",
    "x-reddit",      // prefix: x-reddit-loid, x-reddit-session, …
  ]

  /// Requests whose bodies must never be stored: the token exchange trades
  /// web cookies for a bearer token, so both sides are secret material.
  private static func isCredentialExchange(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.path.hasPrefix("/auth/v2/oauth")
  }

  private static func isSensitive(header name: String) -> Bool {
    let lower = name.lowercased()
    return sensitiveHeaderPatterns.contains { lower == $0 || lower.hasPrefix($0) }
  }

  private static func redacted(_ request: URLRequest) -> URLRequest {
    var copy = request
    if let headers = request.allHTTPHeaderFields {
      for (name, _) in headers where isSensitive(header: name) {
        copy.setValue("<redacted>", forHTTPHeaderField: name)
      }
    }
    if isCredentialExchange(request.url) {
      copy.httpBody = nil
    }
    return copy
  }

  private static func redacted(_ response: HTTPURLResponse) -> HTTPURLResponse {
    guard let url = response.url else { return response }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      guard let name = key as? String else { continue }
      headers[name] = isSensitive(header: name) ? "<redacted>" : (value as? String ?? "\(value)")
    }
    return HTTPURLResponse(
      url: url,
      statusCode: response.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    ) ?? response
  }

  static func log(request: URLRequest, response: HTTPURLResponse?, data: Data?, error: Error?) {
    let credential = isCredentialExchange(request.url)
    LoggerStore.shared.storeRequest(
      redacted(request),
      response: response.map(redacted),
      error: error,
      data: credential ? nil : data,
      label: "network"
    )
  }

  /// HTTPTransport for RedditPOC that logs through Pulse. The token exchanger
  /// shares the client's transport, so auth traffic is captured (and
  /// redacted) too.
  static func makeTransport() -> any HTTPTransport {
    PulseLoggingTransport(wrapped: URLSessionHTTPTransport())
  }
}

/// Wraps another transport, recording each request/response into Pulse.
struct PulseLoggingTransport: HTTPTransport {
  let wrapped: any HTTPTransport

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await wrapped.data(for: request)
      PulseNetworking.log(request: request, response: response, data: data, error: nil)
      return (data, response)
    } catch {
      PulseNetworking.log(request: request, response: nil, data: nil, error: error)
      throw error
    }
  }
}
