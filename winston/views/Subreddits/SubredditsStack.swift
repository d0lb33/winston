//
//  SubredditsStack.swift
//  winston
//
//  Created by Igor Marcossi on 19/09/23.
//
//  The Posts tab root. Now a thin host for the Aurora 3-pane shell (communities
//  sidebar | feed | post+comments), wired to this tab's Router for deep navigation.
//

import SwiftUI

struct SubredditsStack: View {
  @ObservedObject var router: Router

  var body: some View {
    AuroraRoot(router: router)
  }
}
