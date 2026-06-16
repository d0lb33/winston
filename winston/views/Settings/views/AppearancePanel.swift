//
//  Appearance.swift
//  winston
//
//  Created by Igor Marcossi on 05/07/23.
//

import SwiftUI
import Defaults

struct AppearancePanel: View {
  @Default(.PostLinkDefSettings) var postLinkDefSettings
  @Default(.AppearanceDefSettings) var appearanceDefSettings
  @Default(.auroraThemeID) private var auroraThemeID

  @State private var appIconManager = AppIconManger()

  private var postStyleBinding: Binding<PostLinkDisplayStyle> {
    Binding(get: {
      postLinkDefSettings.effectivePostStyle
    }, set: { style in
      postLinkDefSettings.postStyle = style
      postLinkDefSettings.compactMode.enabled = style == .compact
    })
  }

  var body: some View {
    SettingsPanelScrollRoot(topID: "settings-appearance-top") {
      Group {
        AuroraThemePickerSection(selection: $auroraThemeID)

        Section {
          NativeSettingsNavigationRow(value: .setting(.appIcon)) {
            HStack{
              AppIconPreview(icon: appIconManager.current, size: 32, radius: 10)
              Text("App icon")
            }
          }
        }

        Section("General") {
          Toggle("Show Username in Tab Bar", isOn: $appearanceDefSettings.showUsernameInTabBar)
          Toggle("Disable subs list letter sections", isOn: $appearanceDefSettings.disableAlphabetLettersSectionsInSubsList)
        }

        Section("Post Look") {
          Picker("Style", selection: postStyleBinding) {
            ForEach(PostLinkDisplayStyle.allCases) { style in
              Text(style.title).tag(style)
            }
          }
          .pickerStyle(.inline)

          Text(postLinkDefSettings.effectivePostStyle.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Posts") {
          Toggle("Show Upvote Ratio", isOn: $postLinkDefSettings.showUpVoteRatio)
          Toggle("Show Voting Buttons", isOn: $postLinkDefSettings.showVotesCluster)
          Toggle("Show Self Text", isOn: $postLinkDefSettings.showSelfText)
          Toggle("Show Author", isOn: $postLinkDefSettings.showAuthor)
        }

        Section("Compact Posts") {
          Toggle("Show Thumbnail Placeholder", isOn: $postLinkDefSettings.compactMode.showPlaceholderThumbnail)
            Picker("Thumbnail Position", selection: Binding(
              get: { postLinkDefSettings.compactMode.thumbnailSide == .trailing ? "Right" : "Left" },
              set: { postLinkDefSettings.compactMode.thumbnailSide = $0 == "Right" ? .trailing : .leading })
            ){
              Text("Left").tag("Left")
              Text("Right").tag("Right")
            }

            Picker("Thumbnail Size", selection: Binding(get: {
              postLinkDefSettings.compactMode.thumbnailSize
            }, set: { val, _ in
              postLinkDefSettings.compactMode.thumbnailSize = val
            })) {
              Text("Hidden").tag(ThumbnailSizeModifier.hidden)
              Text("Small").tag(ThumbnailSizeModifier.small)
              Text("Medium").tag(ThumbnailSizeModifier.medium)
              Text("Large").tag(ThumbnailSizeModifier.large)
            }

            Picker("Voting Buttons Position", selection: Binding(get: {
              postLinkDefSettings.compactMode.voteButtonsSide == .trailing ? "Right" : "Left"
            }, set: {val, _ in
              postLinkDefSettings.compactMode.voteButtonsSide = val == "Right" ? .trailing : .leading
            })){
              Text("Left").tag("Left")
              Text("Right").tag("Right")
            }
        }

        Section("Accessibility"){
          Toggle("\"Shiny\" Text and Buttons", isOn: $appearanceDefSettings.shinyTextAndButtons)
        }

      }
    }
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct AuroraThemePickerSection: View {
  @Binding var selection: AuroraThemeID

  var body: some View {
    Section {
      ForEach(AuroraThemeID.allCases) { themeID in
        Button {
          selection = themeID
        } label: {
          AuroraThemePickerRow(themeID: themeID, isSelected: selection == themeID)
        }
        .buttonStyle(.plain)
      }
    } header: {
      Text("Theme")
    } footer: {
      Text("Applies to Aurora surfaces immediately.")
    }
  }
}

private struct AuroraThemePickerRow: View {
  let themeID: AuroraThemeID
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      AuroraThemeSwatch(themeID: themeID)

      VStack(alignment: .leading, spacing: 3) {
        Label {
          Text(themeID.displayName)
            .font(.body.weight(.semibold))
        } icon: {
          Image(systemName: themeID.symbol)
            .foregroundStyle(themeID.theme.accent)
        }

        Text(themeID.tagline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if isSelected {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(themeID.theme.accent)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct AuroraThemeSwatch: View {
  let themeID: AuroraThemeID

  private var gradientColors: [Color] {
    let mesh = themeID.theme.meshColors
    return [mesh[0], mesh[4], mesh[8]]
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(themeID.theme.hairline, lineWidth: 0.7)
      )
      .frame(width: 42, height: 42)
  }
}
//
//struct Appearance_Previews: PreviewProvider {
//    static var previews: some View {
//        Appearance()
//    }
//}


//Compact Mode Thumbnail Size Modifiers
enum ThumbnailSizeModifier:  Codable, CaseIterable, Identifiable, Defaults.Serializable{
  var id: CGFloat {
    self.rawVal
  }

  case hidden
  case small
  case medium
  case large

  var rawVal: CGFloat {
    switch self{
    case .hidden:
      return 0.0
    case .small:
      return 0.75
    case .medium:
      return 1.0
    case .large:
      return 1.25
    }
  }
}
