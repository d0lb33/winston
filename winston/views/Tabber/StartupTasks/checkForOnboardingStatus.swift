//
//  checkForOnboardingStatus.swift
//  winston
//
//  Created by Igor Marcossi on 31/12/23.
//

import Foundation
import Defaults

@MainActor
func checkForOnboardingStatus() {
  // Onboarding is just the reddit.com login — present it whenever there's no
  // connected account (fresh install or after a full logout).
  if Defaults[.graphQLAccounts].isEmpty { Nav.present(.onboarding) }
}
