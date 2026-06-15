//
//  measureTabBar.swift
//  winston
//
//  Created by Igor Marcossi on 09/12/23.
//

import SwiftUI

struct TabBarMeasurerAccessor: UIViewControllerRepresentable {
  var setTabBarHeight: (Double) -> Void
  private let proxyController = ViewController()
  
  func makeUIViewController(context: UIViewControllerRepresentableContext<TabBarMeasurerAccessor>) -> UIViewController {
    proxyController.callback = setTabBarHeight
    return proxyController
  }
  
  func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<TabBarMeasurerAccessor>) { }
  
  typealias UIViewControllerType = UIViewController
  
  private class ViewController: UIViewController {
    var callback: (Double) -> Void = { _ in }
    private var lastHeight: Double?
    
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      publishTabBarHeightIfNeeded()
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      publishTabBarHeightIfNeeded()
    }

    private func publishTabBarHeightIfNeeded() {
      if let tabBar = self.tabBarController {
        let bottomSafeArea = tabBar.view.safeAreaInsets.bottom
        let height = max(0, tabBar.tabBar.bounds.height - bottomSafeArea)
        guard lastHeight == nil || abs((lastHeight ?? 0) - height) > 0.5 else {
          return
        }
        lastHeight = height
        DispatchQueue.main.async {
          self.callback(height)
        }
      }
    }
  }
}

extension View {
  func measureTabBar(_ setTabBarHeight: @escaping (Double) -> Void) -> some View {
    self
      .background(TabBarMeasurerAccessor(setTabBarHeight: setTabBarHeight).allowsHitTesting(false))
  }
}
