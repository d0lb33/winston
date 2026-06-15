//
//  consts.swift
//  winston
//
//  Created by Igor Marcossi on 20/07/23.
//

import Foundation
import UIKit
import SwiftUI
import HighlightedTextEditor
import Lottie

let spring = Animation.interpolatingSpring(stiffness: 300, damping: 30, initialVelocity: 0)
let draggingAnimation = Animation.interpolatingSpring(stiffness: 1000, damping: 75, initialVelocity: 0)
let collapsedPresentation = PresentationDetent.height(75)
let redditApiSettingsUrl = URL(string: "https://www.reddit.com/prefs/apps")!
let compactModeThumbSize: CGFloat = 75
let defaultContentWidth: CGFloat = 390
var screenScale: CGFloat { ScreenMetrics.scale }
let colorLottieKeypath = AnimationKeypath(keypath: "**.Color")
let emptyColorLottieKeypath = AnimationKeypath(keypath: "**.EmptyKeyPath")
let feedsAndSuch = ["home", "saved", "all", "popular"]
let IMAGES_FORMATS = [".gif", ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff", ".svg", ".ico", ".heic", ".heif"]
let VIDEOS_FORMATS = [".mov", ".mp4", ".avi", ".mkv", ".flv", ".wmv", ".mpg", ".mpeg", ".webm"]

extension String {
    var urlEncoded: String {
      return self.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
//        let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "~-_."))
//        return self.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet)
    }
}
