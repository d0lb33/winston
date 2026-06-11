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
  @State private var mapped: PostData?

  var body: some View {
    NavigationStack {
      Form {
        librarySection
        if let pd = mapped { mappedSection(pd) }
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
}
