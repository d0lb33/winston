//
//  NativeVoteControl.swift
//  winston
//
//  Shared up / score / down control for the native post + comments screen.
//  Centralises the SF Symbol states, the numeric-text score transition, the
//  generous (44pt-ish) hit targets, and the VoiceOver labels so comment rows and
//  the post action bar stay consistent.
//

import SwiftUI

struct NativeVoteControl: View {
  let likes: Bool?
  let score: Int
  var scoreHidden: Bool = false
  /// Larger styling for the post action bar; compact for comment rows.
  var prominent: Bool = false
  let onUp: () async -> Void
  let onDown: () async -> Void

  private var scoreColor: Color { likes == true ? .orange : likes == false ? .indigo : .secondary }
  private var scoreFont: Font {
    (prominent ? Font.subheadline : Font.footnote).weight(.semibold).monospacedDigit()
  }
  private var symbolFont: Font { prominent ? .body : .footnote }
  private var hitHeight: CGFloat { prominent ? 36 : 32 }

  var body: some View {
    HStack(spacing: 6) {
      Button {
        Task { await onUp() }
      } label: {
        Image(systemName: likes == true ? "arrow.up.circle.fill" : "arrow.up")
          .font(symbolFont)
          .frame(width: 30, height: hitHeight)
          .contentShape(Rectangle())
      }
      .symbolEffect(.bounce, value: likes == true)
      .foregroundStyle(likes == true ? .orange : .secondary)
      .accessibilityLabel("Upvote")
      .accessibilityValue(likes == true ? "Upvoted" : "Not upvoted")

      Text(scoreHidden ? "-" : formatBigNumber(score))
        .font(scoreFont)
        .foregroundStyle(prominent ? (likes == nil ? .primary : scoreColor) : scoreColor)
        .contentTransition(.numericText())
        .accessibilityLabel(scoreHidden ? "Score hidden" : "Score: \(score)")

      Button {
        Task { await onDown() }
      } label: {
        Image(systemName: likes == false ? "arrow.down.circle.fill" : "arrow.down")
          .font(symbolFont)
          .frame(width: 30, height: hitHeight)
          .contentShape(Rectangle())
      }
      .symbolEffect(.bounce, value: likes == false)
      .foregroundStyle(likes == false ? .indigo : .secondary)
      .accessibilityLabel("Downvote")
      .accessibilityValue(likes == false ? "Downvoted" : "Not downvoted")
    }
    .buttonStyle(.borderless)
  }
}
