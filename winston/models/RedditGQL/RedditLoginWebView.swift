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

// MARK: - Onboarding (GraphQL)

/// Fresh-install / add-account login. Presents the reddit.com webview, captures
/// the session on successful login, and hands it to `RedditWire.addAccount`,
/// which mints the Android bearer and registers the account. Replaces the dead
/// REST API-key onboarding when `Defaults[.useGraphQLAPI]` is on.
struct OnboardingGraphQL: View {
  @StateObject private var loginController = WebLoginController()
  @ObservedObject private var wire = RedditWire.shared
  @State private var phase: Phase = .login

  enum Phase: Equatable { case login, connecting, done, failed(String) }

  /// Only allow cancelling once at least one account exists — the very first
  /// login is mandatory (the whole app is gated behind it).
  private var canCancel: Bool { !wire.accounts.isEmpty }

  var body: some View {
    NavigationStack {
      ZStack {
        RedditLoginWebView(controller: loginController) { cookies in
          guard phase == .login else { return }
          phase = .connecting
          Task {
            await wire.addAccount(cookies: cookies)
            if wire.connected {
              phase = .done
              Nav.present(nil)
            } else {
              phase = .failed(wire.status)
            }
          }
        }
        .opacity(phase == .login ? 1 : 0.15)
        .disabled(phase != .login)

        overlayContent
      }
      .navigationTitle("Log in to Reddit")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if canCancel { Button("Cancel") { Nav.present(nil) } }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Capture") { loginController.captureNow?() }
            .disabled(phase != .login)
        }
      }
    }
    .interactiveDismissDisabled(!canCancel)
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
