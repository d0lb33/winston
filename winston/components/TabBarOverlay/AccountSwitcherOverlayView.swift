//
//  AccountSwitcherView.swift
//  winston
//
//  Created by Igor Marcossi on 25/11/23.
//

import SwiftUI
import Defaults

struct AccountSwitcherOverlayView: View, Equatable {
  static func == (lhs: AccountSwitcherOverlayView, rhs: AccountSwitcherOverlayView) -> Bool {
    lhs.fingerPosition == rhs.fingerPosition && lhs.appear == rhs.appear
  }
  
  let fingerPosition: AccountSwitcherTransmitter.PositionInfo
  let appear: Bool
  @ObservedObject var transmitter: AccountSwitcherTransmitter
  
  @ObservedObject private var wire = RedditWire.shared
  @State private var showOverlay = false
  
  
  private let targetsContainerSize: CGSize = .init(width: 250, height: 150)

  var body: some View {
    let accounts = Array(wire.accounts.reversed())
    let showAddBtn = accounts.count < 3
    let targetsCount = accounts.count + (showAddBtn ? 1 : 0)
    let lastsUntilEndOfAllTransitions = transmitter.selectedTarget != nil ? (transmitter.positionInfo != nil || appear) : appear
    ZStack(alignment: .bottom) {
      //        if let screenshot = screenshot {
      //          Image(uiImage: screenshot)
      //            .frame(.screenSize,  .bottom)
      //            .opacity(showOverlay ? 0.9 : 1.0)
      //            .blur(radius: showOverlay ? 2 : 0)
      //            .saturation(showOverlay ? 1.5 : 1.0)
      //            .onAppear { withAnimation(.smooth) { self.showOverlay = true } }
      //            .background(.black)
      //            .transition(.identity)
      //            .allowsHitTesting(false)
      //        }
      
      AccountSwitcherGradientBackground().equatable().opacity(lastsUntilEndOfAllTransitions ? 1 : 0).animation(.easeIn, value: appear)
      
      ZStack {
        if showAddBtn {
          AccountSwitcherTarget(containerSize: targetsContainerSize, index: 0, targetsCount: targetsCount, target: .addAccount, transmitter: transmitter)
        }
        ForEach(Array(accounts.enumerated()), id: \.element) { index, account in
          AccountSwitcherTarget(containerSize: targetsContainerSize, index: index + (showAddBtn ? 1 : 0), targetsCount: targetsCount, target: .account(account), transmitter: transmitter)
        }
        
      }
      .frame(targetsContainerSize)
      .position(fingerPosition.initialLocation)
      .drawingGroup()
      
      AccountSwitcherFingerLight().equatable().position(fingerPosition.location).opacity(!appear ? 0 : 1).animation(.easeOut, value: appear).drawingGroup()
      
      AccountSwitcherParticles().equatable().opacity(lastsUntilEndOfAllTransitions ? 1 : 0).animation(.easeIn, value: appear)
      
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .multilineTextAlignment(.center)
    .ignoresSafeArea(.all)
    .allowsHitTesting(false)
  }
}
