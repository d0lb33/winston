//
//  checkForOnboardingStatus.swift
//  winston
//
//  Created by Igor Marcossi on 31/12/23.
//

import Foundation
import Defaults

func checkForOnboardingStatus() {
  // GraphQL mode: onboarding is just the reddit.com login — present it whenever
  // there's no connected account (fresh install or after a full logout).
  if Defaults[.useGraphQLAPI] {
    if Defaults[.graphQLAccounts].isEmpty { Nav.present(.onboarding) }
    return
  }
  var open = false
  open = switch Defaults[.GeneralDefSettings].onboardingState {
  case .active: true
  case .unknown: RedditCredentialsManager.shared.credentials.isEmpty
  case .dismissed: false
  }
  if open { Nav.present(.onboarding) }
}
