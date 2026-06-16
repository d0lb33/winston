//
//  measureTabBar.swift
//  winston
//
//  Created by Igor Marcossi on 09/12/23.
//

import SwiftUI

struct TabBarMeasurerAccessor: UIViewControllerRepresentable {
  var tabBarMetrics: TabBarMetrics
  private let proxyController = ViewController()
  
  func makeUIViewController(context: UIViewControllerRepresentableContext<TabBarMeasurerAccessor>) -> UIViewController {
    proxyController.tabBarMetrics = tabBarMetrics
    return proxyController
  }
  
  func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<TabBarMeasurerAccessor>) {
    proxyController.tabBarMetrics = tabBarMetrics
  }
  
  typealias UIViewControllerType = UIViewController
  
  private class ViewController: UIViewController {
    var tabBarMetrics: TabBarMetrics?
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
          self.tabBarMetrics?.setHeight(height)
        }
      }
    }
  }
}

extension View {
  func measureTabBar(_ tabBarMetrics: TabBarMetrics) -> some View {
    self
      .background(TabBarMeasurerAccessor(tabBarMetrics: tabBarMetrics).allowsHitTesting(false))
  }
}
