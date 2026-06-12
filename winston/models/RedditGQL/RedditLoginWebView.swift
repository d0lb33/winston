//
//  RedditLoginWebView.swift
//  winston
//
//  In-app reddit.com login webview. Captures the session cookies once the user
//  is logged in; the cookies are handed to RedditWire, which builds a RedditPOC
//  WebSession and mints the Android bearer.
//

import SwiftUI
import WebKit
import RedditPOC

/// Lets the toolbar's "Capture now" button force a cookie read on the coordinator.
final class WebLoginController: ObservableObject {
  var captureNow: (() -> Void)?
}

/// A WKWebView that loads reddit.com/login and reports back once a logged-in
/// `reddit_session` cookie appears.
struct RedditLoginWebView: UIViewRepresentable {
  /// Bridge so the toolbar's "Capture now" button can force a cookie read.
  var controller: WebLoginController
  /// Called (on main) with all webview cookies once login is detected.
  var onCaptured: ([HTTPCookie]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // Fresh data store so we don't collide with anything else.
    config.websiteDataStore = .nonPersistent()
    config.applicationNameForUserAgent = "Version/16.0 Mobile/15E148 Safari/604.1"

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.customUserAgent = RedditConstants.androidUserAgent
    webView.navigationDelegate = context.coordinator
    config.websiteDataStore.httpCookieStore.add(context.coordinator)
    context.coordinator.webView = webView
    controller.captureNow = { [weak coordinator = context.coordinator] in coordinator?.captureNow() }
    webView.load(URLRequest(url: RedditConstants.loginURL))
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let onCaptured: ([HTTPCookie]) -> Void
    weak var webView: WKWebView?
    private var fired = false

    init(onCaptured: @escaping ([HTTPCookie]) -> Void) { self.onCaptured = onCaptured }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
      cookieStore.getAllCookies { [weak self] cookies in
        self?.evaluate(cookies)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        self?.evaluate(cookies)
      }
    }

    /// Manually pull current cookies (used by the "Capture now" fallback button).
    func captureNow() {
      webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        self?.fire(cookies, force: true)
      }
    }

    private func evaluate(_ cookies: [HTTPCookie]) {
      let session = cookies.first { $0.name == "reddit_session" }
      // A logged-out reddit_session is short/absent; a non-trivial value means logged in.
      if let session, session.value.count > 20 {
        fire(cookies, force: false)
      }
    }

    private func fire(_ cookies: [HTTPCookie], force: Bool) {
      guard !fired || force else { return }
      fired = true
      DispatchQueue.main.async { self.onCaptured(cookies) }
    }
  }
}

/// WKWebView used when Reddit/Cloudflare challenges the GraphQL host. It loads
/// `gql-fed.reddit.com`, lets the user complete the challenge, then returns any
/// cookies issued by that host so they can be attached to future GraphQL calls.
struct RedditChallengeWebView: UIViewRepresentable {
  var controller: WebLoginController
  var seedCookies: [HTTPCookie]
  var onCaptured: ([HTTPCookie]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.applicationNameForUserAgent = "Version/16.0 Mobile/15E148 Safari/604.1"

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    controller.captureNow = { [weak coordinator = context.coordinator] in coordinator?.captureNow() }

    let store = config.websiteDataStore.httpCookieStore
    let group = DispatchGroup()
    seedCookies.forEach { cookie in
      group.enter()
      store.setCookie(cookie) { group.leave() }
    }
    group.notify(queue: .main) {
      webView.load(URLRequest(url: RedditConstants.gqlFedURL))
    }
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate {
    let onCaptured: ([HTTPCookie]) -> Void
    weak var webView: WKWebView?

    init(onCaptured: @escaping ([HTTPCookie]) -> Void) { self.onCaptured = onCaptured }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard cookies.contains(where: { $0.name == "cf_clearance" || $0.name.hasPrefix("__cf") || $0.name.hasPrefix("cf_") }) else { return }
        DispatchQueue.main.async { self?.onCaptured(cookies) }
      }
    }

    func captureNow() {
      webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        DispatchQueue.main.async { self?.onCaptured(cookies) }
      }
    }
  }
}

// MARK: - Onboarding (GraphQL)

/// Fresh-install / add-account login. Presents the reddit.com webview, captures
/// the session on successful login, and hands it to `RedditWire.addAccount`,
/// which mints the Android bearer and registers the account. Replaces the dead
/// REST API-key onboarding when `Defaults[.useGraphQLAPI]` is on.
struct OnboardingGraphQL: View {
  @StateObject private var loginController = WebLoginController()
  @StateObject private var challengeController = WebLoginController()
  @ObservedObject private var wire = RedditWire.shared
  @State private var phase: Phase = .login
  @State private var loginCookies: [HTTPCookie] = []

  enum Phase: Equatable { case login, connecting, challenge(String), done, failed(String) }

  /// Only allow cancelling once at least one account exists — the very first
  /// login is mandatory (the whole app is gated behind it).
  private var canCancel: Bool { !wire.accounts.isEmpty }

  var body: some View {
    NavigationStack {
      ZStack {
        Group {
          switch phase {
          case .login, .connecting, .done, .failed(_):
            RedditLoginWebView(controller: loginController) { cookies in
              guard phase == .login else { return }
              loginCookies = cookies
              connect(cookies: cookies)
            }
          case .challenge(_):
            RedditChallengeWebView(controller: challengeController, seedCookies: loginCookies) { cookies in
              guard case .challenge = phase else { return }
              connect(cookies: mergedCookies(loginCookies, cookies))
            }
          }
        }
        .opacity(phase == .login || isChallengePhase ? 1 : 0.15)
        .disabled(!(phase == .login || isChallengePhase))

        overlayContent
      }
      .navigationTitle("Log in to Reddit")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if canCancel { Button("Cancel") { Nav.present(nil) } }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Capture") {
            if isChallengePhase {
              challengeController.captureNow?()
            } else {
              loginController.captureNow?()
            }
          }
            .disabled(!(phase == .login || isChallengePhase))
        }
      }
    }
    .interactiveDismissDisabled(!canCancel)
  }

  private var isChallengePhase: Bool {
    if case .challenge = phase { return true }
    return false
  }

  private func connect(cookies: [HTTPCookie]) {
    phase = .connecting
    Task {
      await wire.addAccount(cookies: cookies)
      if wire.connected {
        phase = .done
        Nav.present(nil)
      } else if wire.status.localizedCaseInsensitiveContains("browser challenge") {
        phase = .challenge(wire.status)
      } else {
        phase = .failed(wire.status)
      }
    }
  }

  private func mergedCookies(_ lhs: [HTTPCookie], _ rhs: [HTTPCookie]) -> [HTTPCookie] {
    let pairs = (lhs + rhs).map { ("\($0.domain)|\($0.path)|\($0.name)", $0) }
    return Array(Dictionary(pairs, uniquingKeysWith: { _, new in new }).values)
  }

  @ViewBuilder private var overlayContent: some View {
    switch phase {
    case .login:
      EmptyView()
    case .connecting:
      statusCard {
        ProgressView().controlSize(.large)
        Text("Signing you in…").font(.headline)
      }
    case .challenge(let msg):
      VStack {
        Spacer()
        VStack(spacing: 12) {
          Image(systemName: "shield.lefthalf.filled").font(.largeTitle).foregroundStyle(.orange)
          Text("Complete Reddit Check").font(.headline)
          Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("I’m done") { challengeController.captureNow?() }.buttonStyle(.borderedProminent)
          Button("Back to login") { phase = .login }.buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
      }
    case .done:
      statusCard {
        Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
        Text("Logged in!").font(.headline)
      }
    case .failed(let msg):
      statusCard {
        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
        Text("Login failed").font(.headline)
        Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("Try again") { phase = .login }.buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder private func statusCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    VStack(spacing: 12) { content() }
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
  }
}
