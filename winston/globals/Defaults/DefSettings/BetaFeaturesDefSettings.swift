//
//  BetaFeaturesDefSettings.swift
//  winston
//
//  Opt-in flags for experimental ("BETA") features that aren't ready to be the default.
//

import Defaults

struct BetaFeaturesDefSettings: Equatable, Hashable, Codable, Defaults.Serializable {
  /// Routes fullscreen image/GIF/video through the new `AuroraMediaViewer` (liquid-glass,
  /// follow-finger dismiss, press-and-hold horizontal scrub). Off ⇒ legacy LightBoxImage / FullScreenVP.
  var newMediaViewer: Bool = false
}
