//
//  TabBarOverlay.swift
//  winston
//
//  Created by Igor Marcossi on 19/09/23.
//

import SwiftUI



struct TabBarOverlay: View {
  var meTabTap: () -> ()
  
  @Environment(TabBarMetrics.self) private var tabBarMetrics
  var body: some View {
    if let tabBarHeight = tabBarMetrics.height {
      GeometryReader { geo in
        let overlaySize = CGSize(width: geo.size.width, height: max(0, (tabBarHeight)))
        let tabs = Nav.TabIdentifier.allCases
        let tabWidth = overlaySize.width / CGFloat(tabs.count)
        let meIndex = tabs.firstIndex(of: .me) ?? 0
        let meCenterX = (CGFloat(meIndex) + 0.5) * tabWidth
        let meHitWidth = min(tabWidth, 96)
        let bottomSafeArea = geo.safeAreaInsets.bottom
        AccountSwitcherTrigger(onTap: meTabTap) {
          Color.clear
            .frame(width: meHitWidth, height: overlaySize.height)
            .background(Color.hitbox)
            .contentShape(Rectangle())
        }
        .frame(width: meHitWidth, height: overlaySize.height)
        .position(x: meCenterX, y: geo.size.height - bottomSafeArea - (overlaySize.height / 2))
      }
      .ignoresSafeArea(.all)
    }
  }
}


struct SimpleTappableView: UIViewRepresentable {
  var onTap: () -> Void
  
  private let view = TappableUIView()
  
  func makeUIView(context: Context) -> UIButton {
    addTapRecognizer(to: view, with: context)
    return view
  }
  
  func updateUIView(_ uiView: UIButton, context: Context) { }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }
  
  private func addTapRecognizer(to view: UIButton, with context: Context) {
    let recognizer = UITapGestureRecognizer()
    recognizer.delaysTouchesBegan = false
    recognizer.delegate = context.coordinator
    recognizer.addTarget(context.coordinator, action: #selector(Coordinator.handleTap))
    view.addGestureRecognizer(recognizer)
  }
  
  class Coordinator: NSObject, UIGestureRecognizerDelegate {
    
    private var parent: SimpleTappableView
    
    init(parent: SimpleTappableView) {
      self.parent = parent
    }
    
    @objc fileprivate func handleTap(_ sender: UITapGestureRecognizer) {
      if case .ended = sender.state {
        parent.onTap()
      }
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer {
        return true
      }
      return false
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer is UIPanGestureRecognizer {
        return false
      }
      return true
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if let recognizer = gestureRecognizer as? UIPanGestureRecognizer {
        let velocity = recognizer.velocity(in: recognizer.view)
        return abs(velocity.x) > abs(velocity.y)
      }
      return true
    }
  }
}
