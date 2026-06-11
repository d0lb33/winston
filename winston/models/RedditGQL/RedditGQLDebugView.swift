//
//  RedditGQLDebugView.swift
//  winston
//
//  EXPERIMENTAL: verification UI for the RedditPOC GraphQL path.
//  Connect via reddit.com login → mint Android bearer (RedditPOC) → fetch a
//  post over GraphQL → adapt into Winston's PostData → render it.
//

import SwiftUI

struct RedditGQLDebugView: View {
  @ObservedObject private var wire = RedditWire.shared
  @Environment(\.dismiss) private var dismiss

  @State private var presentingLogin = false
  @State private var busy = false
  @State private var postID = "t3_1q8ju15"
  @State private var subName = "apple"
  @State private var mapped: PostData?
  @State private var captureOut = ""

  var body: some View {
    NavigationStack {
      Form {
        librarySection
        if let pd = mapped { mappedSection(pd) }
        if wire.connected { captureSection }
      }
      .navigationTitle("RedditPOC (experimental)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $presentingLogin) { loginSheet }
    }
  }

  // MARK: Capture (Phase 1)

  @ViewBuilder private var captureSection: some View {
    Section("Capture (Phase 1 — dumps to console: GQLBODY)") {
      TextField("subreddit", text: $subName)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button { runCapture { await wire.captureSubredditFeed(subName) } } label: {
        Label("Capture subredditFeedSdui", systemImage: "square.stack.3d.up")
      }
      Button { runCapture { await wire.captureHomeFeed() } } label: {
        Label("Capture homeFeedSdui", systemImage: "house")
      }
      Button { runCapture { await wire.capturePostComments(postID) } } label: {
        Label("Capture postComments", systemImage: "text.bubble")
      }
      Button { runCapture { await wire.captureGetAccount() } } label: {
        Label("Capture getAccount", systemImage: "person.text.rectangle")
      }
      Button { runCapture { await wire.captureUserSubreddits() } } label: {
        Label("Capture userSubreddits", systemImage: "person.3")
      }
      if !captureOut.isEmpty {
        ScrollView { Text(captureOut).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
          .frame(height: 160)
      }
    }
    .disabled(busy)
  }

  private func runCapture(_ op: @escaping () async -> String) {
    busy = true
    captureOut = "Capturing… (full body in console: filter GQLBODY)"
    Task {
      let result = await op()
      captureOut = String(result.prefix(2000))
      busy = false
    }
  }

  // MARK: Library section

  @ViewBuilder private var librarySection: some View {
    Section("RedditPOC") {
      Text(wire.status).font(.caption).foregroundStyle(.secondary)
      if wire.connected {
        TextField("t3_…", text: $postID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button { runMap() } label: {
          Label("Fetch & render post (PostsByIds)", systemImage: "shippingbox")
        }
        Button { runFeed() } label: {
          Label("Load feed (r/\(subName)) — first post", systemImage: "list.bullet.rectangle")
        }
        Button { runComments() } label: {
          Label("Load comments (\(postID))", systemImage: "text.bubble")
        }
        Button { runVoteSaveTest() } label: {
          Label("Test vote+save (up→clear, save→unsave)", systemImage: "arrow.up.arrow.down")
        }
        Button { runMeSubs() } label: {
          Label("Load me + subscriptions", systemImage: "person.crop.circle")
        }
        Button(role: .destructive) {
          Task { await wire.disconnect(); mapped = nil }
        } label: { Text("Disconnect") }
      } else {
        Text("Not connected. Log in to reddit.com to mint an Android bearer via RedditPOC.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button { presentingLogin = true } label: {
          Label("Connect via RedditPOC", systemImage: "person.crop.circle.badge.plus")
        }
      }
    }
    .disabled(busy)
  }

  // MARK: Rendered adapted post

  private func mappedSection(_ pd: PostData) -> some View {
    Section("Adapted PostData → rendered") {
      VStack(alignment: .leading, spacing: 6) {
        Text(pd.subreddit_name_prefixed).font(.caption).foregroundStyle(.secondary)
        Text(pd.title).font(.headline)
        if let flair = pd.link_flair_text, !flair.isEmpty {
          Text(flair).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        if !pd.selftext.isEmpty {
          Text(pd.selftext).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        }
        HStack(spacing: 14) {
          Label("\(pd.ups)", systemImage: pd.likes == true ? "arrow.up.circle.fill" : "arrow.up.circle")
          Label("\(pd.num_comments)", systemImage: "bubble.right")
          Text("u/\(pd.author)").foregroundStyle(.secondary)
          if pd.over_18 == true { Text("NSFW").foregroundStyle(.red) }
        }
        .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: Login sheet

  @ViewBuilder private var loginSheet: some View {
    let controller = WebLoginController()
    NavigationStack {
      RedditLoginWebView(controller: controller) { cookies in
        presentingLogin = false
        Task { busy = true; await wire.connect(cookies: cookies); busy = false }
      }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("Log in to Reddit")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { presentingLogin = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Capture now") { controller.captureNow?() }
        }
      }
    }
  }

  private func runMap() {
    busy = true
    mapped = nil
    Task {
      mapped = await wire.postData(forID: postID)
      busy = false
    }
  }

  private func runFeed() {
    busy = true
    mapped = nil
    Task {
      let (posts, _) = await wire.feedPosts(subreddit: subName, isHome: false)
      mapped = posts.first
      busy = false
    }
  }

  private func runMeSubs() {
    busy = true
    captureOut = "loading me + subscriptions…"
    Task {
      let me = await wire.me()
      let subs = await wire.subscriptions()
      captureOut = """
      me: u/\(me?.name ?? "?")  id: \(me?.id ?? "?")
      karma: total \(me?.total_karma ?? -1), comment \(me?.comment_karma ?? -1), link \(me?.link_karma ?? -1)
      avatar: \(me?.snoovatar_img ?? me?.icon_img ?? "—")
      subscriptions: \(subs.count)
      first: \(subs.prefix(8).compactMap { $0.display_name }.joined(separator: ", "))
      """
      busy = false
    }
  }

  private func runVoteSaveTest() {
    busy = true
    captureOut = "testing vote/save on \(postID)…"
    Task {
      let p = postID
      let up = await wire.vote(fullname: p, action: .up)
      let clear = await wire.vote(fullname: p, action: .none)
      let saved = await wire.save(fullname: p, saved: true)
      let unsaved = await wire.save(fullname: p, saved: false)
      captureOut = "vote up: \(up)\nvote clear: \(clear)\nsave: \(saved)\nunsave: \(unsaved)\n(net-neutral; state restored)"
      busy = false
    }
  }

  private func runComments() {
    busy = true
    captureOut = "loading comments…"
    Task {
      let bare = postID.hasPrefix("t3_") ? String(postID.dropFirst(3)) : postID
      let post = Post(id: bare)
      let result = await post.refreshPost(full: true)
      let comments = result?.0 ?? []
      let first = comments.first
      let kids = first?.childrenWinston.data.count ?? 0
      captureOut = "comments: \(comments.count) roots (first has \(kids) replies)\nfirst: u/\(first?.data?.author ?? "?")\n\(first?.data?.body?.prefix(160) ?? "")"
      busy = false
    }
  }
}
