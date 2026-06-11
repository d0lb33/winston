//
//  SubredditRulesTab.swift
//  winston
//
//  Created by Igor Marcossi on 19/07/23.
//

import SwiftUI
import MarkdownUI

struct SubredditRulesTab: View {
  @ObservedObject var subreddit: Subreddit
  @State private var loading = true
  @State private var rules: [SubredditRuleSummary]?
    var body: some View {
      if loading {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 400)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
          .onAppear {
            Task(priority: .background) {
              if let newRules = await subreddit.fetchRules() {
                withAnimation {
                  rules = newRules
                }
              }
              withAnimation {
                loading = false
              }
            }
          }
      } else {
        if let rules, !rules.isEmpty {
          Section {
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
              SubredditRuleRow(index: index + 1, rule: rule)
            }
          }
        } else {
          Text("No rules were returned for r/\(subreddit.data?.display_name ?? subreddit.id)")
        }
      }
    }
}

private struct SubredditRuleRow: View {
  let index: Int
  let rule: SubredditRuleSummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(String(index))
        .frame(width: 24, height: 24)
        .fontSize(16, .semibold)
        .background(Color.accentColor, in: Circle())
        .foregroundColor(.white)

      VStack(alignment: .leading, spacing: 6) {
        Text(rule.name)
          .fontSize(22, .bold)

        let text = MarkdownUtil.formatForMarkdown(rule.markdown)
        Markdown(text.isEmpty ? "Rule without description." : text)
          .markdownTheme(.winstonMarkdown(fontSize: 16))
      }
    }
    .multilineTextAlignment(.leading)
  }
}
