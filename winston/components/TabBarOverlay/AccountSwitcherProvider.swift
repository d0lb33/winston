//
//  AccountSwitcherProvider.swift
//  winston
//
//  Created by Igor Marcossi on 27/11/23.
//

import SwiftUI
import Combine
import Defaults

/// What a switcher bubble points at: a connected account or the "add" button.
enum AccountSwitcherTargetID: Equatable, Hashable {
  case account(RedditAccount)
  case addAccount
}

class AccountSwitcherTransmitter: ObservableObject {
  private var cancellable: Timer? = nil
  @Published var positionInfo: PositionInfo? { willSet { self.cancellable?.invalidate() } }
  @Published var showing = false { willSet { if newValue { self.cancellable?.invalidate() } } }
  @Published var selectedTarget: AccountSwitcherTargetID? = nil
  @Published var screenshot: UIImage? = nil
  
  func scheduleReset(_ secs: Double) {
    cancellable = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in
      self.reset()
    }
  }
  
  func reset() {
    self.cancellable?.invalidate()
    self.positionInfo = nil
    self.showing = false
    self.selectedTarget = nil
    self.screenshot = nil
  }
  
  struct PositionInfo: Equatable, Hashable {
    static let zero = PositionInfo(.zero)
    private var _location: CGPoint? = nil
    var location: CGPoint {
      get { _location ?? initialLocation }
      set { _location = newValue }
    }
    var initialMovement: Bool { _location == nil }
    let initialLocation: CGPoint
    
    init(_ loc: CGPoint) {
      self.initialLocation = loc
    }
  }
}

struct AccountSwitcherProvider<Content: View>: View {
  struct AccountTransitionKit: Equatable {
    var focusCloser: Bool = false
    var willLensHeadLeft: Bool = false
    var passLens: Bool = false
    var blurMain: Bool = false
  }
  
  @StateObject private var transmitter = AccountSwitcherTransmitter()
  @Environment(\.displayScale) private var displayScale
  //  @State private var credIDToSelect: UUID? = nil
  @State private var accTransKit: AccountTransitionKit = .init()
  /// Live window size — drives the side-by-side mask as the scene rotates/resizes.
  @State private var windowSize: CGSize = CGSize(width: 1, height: 1)

  var content: () -> Content
  
  func selectAccount() {
    guard let target = transmitter.selectedTarget else {
      transmitter.scheduleReset(0.5)
      return
    }
    switch target {
    case .addAccount:
      // The "+" bubble opens the reddit.com login webview.
      doThisAfter(0) {
        transmitter.reset()
        Nav.present(.onboarding)
      }
    case .account(let account):
      let accounts = RedditWire.shared.accounts
      let nextIndex = accounts.firstIndex(of: account) ?? 0
      let selID = Defaults[.GeneralDefSettings].redditCredentialSelectedID
      let currIndex = accounts.firstIndex { $0.id == selID } ?? -1
      accTransKit.willLensHeadLeft = Int(currIndex - nextIndex) <= 0
      transmitter.selectedTarget = nil
      withAnimation(.snappy(extraBounce: 0.1)) { accTransKit.focusCloser = true } completion: {
        withAnimation(.linear(duration: 0.001)) {
          accTransKit.blurMain = true
          Task { await RedditWire.shared.selectAccount(account.id) }
        } completion: {
          withAnimation(.spring) { accTransKit.passLens = true } completion: {
            withAnimation(.spring) { transmitter.positionInfo = nil; accTransKit.blurMain = false; transmitter.screenshot = nil; accTransKit.focusCloser = false;  } completion: {
              accTransKit.passLens = false
            }
          }
        }
      }
    }
  }
  
  var body: some View {
    let showOverlay = (transmitter.positionInfo != nil && transmitter.showing) || accTransKit.focusCloser
    let transitionActive = accTransKit.focusCloser || accTransKit.passLens
    //    let completelyFree = true
    let focusFramePadding: Double = accTransKit.focusCloser ? 40 : 0
    let frameSlideOffsetX = accTransKit.passLens ? (windowSize.width * (accTransKit.willLensHeadLeft ? -1 : 1)) : 0
    ZStack {
      
      ZStack {
        content()
          .blur(radius: accTransKit.blurMain ? 10 : 0)
        //          .offset(x: accTransKit.passLens ? 0 : accTransKit.focusCloser ? (parallaxW * (accTransKit.willLensHeadLeft ? -1 : 1)) : 0)
          .environmentObject(transmitter)
          .zIndex(1)
        
        if transitionActive, let screenshot = transmitter.screenshot {
          Image(uiImage: screenshot).resizable().frame(windowSize)
            .blur(radius: accTransKit.focusCloser ? 15 : transmitter.showing ? 10 : 0)
          //            .offset(x: accTransKit.passLens ? (parallaxW * (accTransKit.willLensHeadLeft ? -1 : 1)) : 0)
            .background(.black)
          //            .offset(x: frameSlideOffsetX / 5)
            .mask(Rectangle().fill(.black).offset(x: frameSlideOffsetX))
            .saturation(accTransKit.focusCloser ? 2 : transmitter.showing ? 1.75 : 1)
            .transition(.identity)
            .zIndex(2)
            .drawingGroup()
            .allowsHitTesting(false)
        }
      }
      .overlay {
        SideBySideWindow(passLens: accTransKit.passLens, willLensHeadLeft: accTransKit.willLensHeadLeft, size: windowSize) {
          Rectangle().fill(
            EllipticalGradient(
              colors: [.gray.opacity(0.5), .gray.opacity(0.2)],
              center: .init(x: !transmitter.showing ? 1 : accTransKit.focusCloser ? 0.55 : 0.75, y: 0),
              startRadiusFraction: 0,
              endRadiusFraction: 0.85)
          )
          .padding(.all, focusFramePadding)
          .opacity(!transitionActive ? 0 : 1)
        }
        .allowsHitTesting(false)
      }
      .mask(
        Group {
          if transitionActive {
            SideBySideWindow(passLens: accTransKit.passLens, willLensHeadLeft: accTransKit.willLensHeadLeft, size: windowSize) {
              RR(accTransKit.focusCloser ? 40 : 48, .black).padding(.all, focusFramePadding)
            }
          } else {
            Rectangle().fill(.black)
              .ignoresSafeArea(.all)
          }
        }
      )
      .background(transitionActive ? Color(.primaryInverted) : Color.clear)
      .animation(.spring, value: transmitter.showing)
      
      if let positionInfo = transmitter.positionInfo {
        AccountSwitcherOverlayView(fingerPosition: positionInfo, appear: transmitter.showing, transmitter: transmitter).equatable().zIndex(3).allowsHitTesting(false)
          .ignoresSafeArea(.all)
          .zIndex(3)
          .onAppear { transmitter.showing = true }
          .onChange(of: transmitter.showing) { _, showing in if !showing { selectAccount() } }
          .allowsHitTesting(false)
      }
    }
    // A geometry change (rotation / resize / fold) is only used as a re-render trigger.
    // `proxy.size` here reports the safe-area-inset size, which would make the mask shorter
    // than the window and clip the top/bottom. The mask must cover the FULL window, so we
    // refresh the live metrics and use the current window bounds as the size.
    .onGeometryChange(for: AccountSwitcherViewportMetrics.self) { proxy in
      AccountSwitcherViewportMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
    } action: { metrics in
      let fullSize = metrics.fullSize
      ScreenMetrics.refresh(size: fullSize, scale: displayScale, safeAreaInsets: metrics.uiEdgeInsets)
      windowSize = fullSize
    }
    .allowsHitTesting(!(showOverlay || accTransKit.passLens))
  }
}

private struct AccountSwitcherViewportMetrics: Equatable {
  let size: CGSize
  let top: CGFloat
  let leading: CGFloat
  let bottom: CGFloat
  let trailing: CGFloat

  init(size: CGSize, safeAreaInsets: EdgeInsets) {
    self.size = size
    self.top = safeAreaInsets.top
    self.leading = safeAreaInsets.leading
    self.bottom = safeAreaInsets.bottom
    self.trailing = safeAreaInsets.trailing
  }

  var fullSize: CGSize {
    CGSize(width: size.width + leading + trailing, height: size.height + top + bottom)
  }

  var uiEdgeInsets: UIEdgeInsets {
    UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
  }
}

struct SideBySideWindow<C: View>: View {
  var passLens: Bool
  var willLensHeadLeft: Bool
  /// Live window size, measured at render time by the parent.
  var size: CGSize
  @ViewBuilder var content: () -> C
  var body: some View {
    HStack(spacing: 0) {
      Group {
        content()
        content()
      }
      .frame(size)
    }
    .frame(width: size.width * 2, alignment: .leading)
    .scaleEffect(1)
    .offset(x: passLens ? (size.width * (willLensHeadLeft ? -1 : 1)) : 0)
    .frame(width: size.width, alignment: willLensHeadLeft ? .leading : .trailing)
    .allowsHitTesting(false)
    .clipped()
    .drawingGroup()
  }
}
