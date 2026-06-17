//
//  NativeSettingsComponents.swift
//  winston
//
//  Settings-only list and row primitives that follow the stock iOS Settings
//  presentation without changing Aurora surfaces elsewhere in the app.
//

import SwiftUI

struct NativeSettingsListModifier: ViewModifier {
  @Environment(TabBarMetrics.self) private var tabBarMetrics

  func body(content: Content) -> some View {
    content
      .listStyle(.insetGrouped)
      .tint(.accentColor)
      .contentMargins(.bottom, (tabBarMetrics.height ?? 0) + 20, for: .scrollContent)
  }
}

extension View {
  func nativeSettingsList() -> some View {
    modifier(NativeSettingsListModifier())
  }
}

struct SettingsPanelScrollRoot<Content: View>: View {
  private let content: () -> Content

  init(
    topID: String,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.content = content
  }

  var body: some View {
    List {
      content()
    }
    .nativeSettingsList()
  }
}

struct SettingsIcon: View {
  let systemImage: String
  var color: Color = .accentColor

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 29, height: 29)
      .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .accessibilityHidden(true)
  }
}

private struct SettingsIconLabel: View {
  let title: LocalizedStringKey
  let systemImage: String
  let iconColor: Color

  var body: some View {
    Label {
      Text(title)
    } icon: {
      SettingsIcon(systemImage: systemImage, color: iconColor)
    }
  }
}

struct NativeSettingsActionRow<Label: View>: View {
  var role: ButtonRole?
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  init(role: ButtonRole? = nil, _ action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
    self.role = role
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(role: role, action: action) {
      HStack(spacing: 12) {
        label()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension NativeSettingsActionRow where Label == AnyView {
  init(
    title: LocalizedStringKey,
    systemImage: String? = nil,
    iconColor: Color = .accentColor,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.role = role
    self.action = action
    self.label = {
      if let systemImage {
        AnyView(SettingsIconLabel(title: title, systemImage: systemImage, iconColor: iconColor))
      } else {
        AnyView(Text(title))
      }
    }
  }
}

struct NativeSettingsNavigationRow<Label: View>: View {
  let value: NavDest
  var active = false
  @ViewBuilder let label: () -> Label

  @Environment(\.settingsNavigationModel) private var settingsNavigationModel
  @Environment(\.settingsNavigationOrigin) private var settingsNavigationOrigin
  @Environment(\.redditNavigationModel) private var redditNavigationModel
  @Environment(\.redditNavigationOrigin) private var redditNavigationOrigin
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(_ value: NavDest, active: Bool = false, @ViewBuilder label: @escaping () -> Label) {
    self.value = value
    self.active = active
    self.label = label
  }

  init(value: NavDest, active: Bool = false, @ViewBuilder label: @escaping () -> Label) {
    self.value = value
    self.active = active
    self.label = label
  }

  var body: some View {
    Button {
      AppDiagnostics.asyncBreadcrumb("NativeSettingsNavigationRow tapped", metadata: ["destination": value.diagnosticsName])
      if navigateSettingsDestination(value, model: settingsNavigationModel, origin: settingsNavigationOrigin) {
        return
      }
      navigateRedditDestination(value, model: redditNavigationModel, origin: redditNavigationOrigin)
    } label: {
      HStack(spacing: 12) {
        label()
          .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(rowBackground)
  }

  private var rowBackground: Color? {
    guard active, horizontalSizeClass == .regular else { return nil }
    return Color.accentColor.opacity(0.14)
  }
}

extension NativeSettingsNavigationRow where Label == AnyView {
  init(
    _ value: NavDest,
    active: Bool = false,
    title: LocalizedStringKey,
    systemImage: String? = nil,
    iconColor: Color = .accentColor
  ) {
    self.value = value
    self.active = active
    self.label = {
      if let systemImage {
        AnyView(SettingsIconLabel(title: title, systemImage: systemImage, iconColor: iconColor))
      } else {
        AnyView(Text(title))
      }
    }
  }
}
