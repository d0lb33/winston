//
//  TakeSnapshotView.swift
//  winston
//
//  Created by Igor Marcossi on 25/11/23.
//

import SwiftUI

struct TakeSnapshotView: UIViewRepresentable {
  @Binding var screenshot: UIImage?
  var takeScreenshot = false
  func makeUIView(context: Context) -> UIView {
    context.coordinator.parent = self
    let view = UIView()
    context.coordinator.hostView = view
    return view
  }
  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.hostView = view
    if takeScreenshot && screenshot == nil { context.coordinator.takeScreenshotAndSave() }
  }
  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }
  
  class Coordinator: NSObject {
    var parent: TakeSnapshotView
    weak var hostView: UIView?
    
    init(parent: TakeSnapshotView) {
      self.parent = parent
    }
    
    func takeScreenshotAndSave() {
      guard let view = hostView?.window?.rootViewController?.view else {
        return
      }
      
      // Create an image renderer
      let renderer = UIGraphicsImageRenderer(size: view.bounds.size)
      
      // Render the view into an image
      let screenshotImage = renderer.image { context in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
      }
      
      // Save the screenshot to the Photos library
      DispatchQueue.main.async {
        self.parent.screenshot = screenshotImage
      }
    }
//    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
//      if let error = error {
//        // Handle error saving the image
////        showToast(message: "Error saving image: \(error.localizedDescription)")
//        print("ScreenShot Tuken :(")
//      } else {
//        // Image saved successfully
//        print("ScreenShot Taken")
//      }
//    }
  }
}
