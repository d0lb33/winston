//
//  SelectableTextSheet.swift
//  winston
//
//  Dedicated "select & copy" surface for post/comment bodies.
//
//  Inline body text is intentionally NON-selectable so tap-to-collapse stays
//  instant — selectable text installs UIKit text-interaction recognizers
//  (long-press + single/double-tap) that an enclosing collapse `.onTapGesture`
//  must wait to fail, which was the ~100–200ms tap lag. Selection lives here
//  instead: a long-press → context menu → this sheet, where the same markdown is
//  re-rendered with selection enabled. Mirrors how first-party readers split
//  "tap to collapse" from "long-press to select".
//

import SwiftUI
import UIKit
import MarkdownUI

struct SelectableTextSheet: View {
  let markdown: String
  var title: String = "Select Text"

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        Markdown(MarkdownUtil.formatForMarkdown(markdown, showSpoiler: true))
          // `textSelection: true` flows through to the per-block `.textSelection(.enabled)`
          // in `winstonMarkdown`, making every paragraph/heading/quote selectable.
          .markdownTheme(.winstonMarkdown(fontSize: 17, lineSpacing: 3, textSelection: true))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            UIPasteboard.general.string = markdown
          } label: {
            Label("Copy All", systemImage: "doc.on.doc")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

extension View {
  /// Adds a "Select Text" item to a context menu and presents `SelectableTextSheet`.
  /// Pass the same raw markdown the inline body renders. The `isPresented` binding lets
  /// the caller put the `Button` inside its own `.contextMenu` (so it composes with the
  /// site's existing menu items) and attach the sheet via this modifier.
  func selectableTextSheet(isPresented: Binding<Bool>, markdown: String, title: String = "Select Text") -> some View {
    sheet(isPresented: isPresented) {
      SelectableTextSheet(markdown: markdown, title: title)
    }
  }
}
