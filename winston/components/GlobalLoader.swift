//
//  GlobalLoader.swift
//  winston
//
//  Created by Igor Marcossi on 08/08/23.
//

import Foundation
import SwiftUI

struct GlobalLoaderView: View {
  var loader: GlobalLoaderModel

  var body: some View {
    let loadingText = loader.loadingText
    let displayText: String = if let loadingText {
      loadingText
    } else {
      "Done!"
    }
    HStack(spacing: 8) {
      if loadingText == nil {
        Image(systemName: "checkmark.circle.fill")
          .transition(.scaleAndBlur)
          .foregroundColor(.green)
      } else {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .teal))
          .transition(.scaleAndBlur)
      }
      
      Text(verbatim: displayText)
        .foregroundColor(loadingText == nil ? .green : .teal)
        .fontSize(15, .semibold)
        .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top)).combined(with: .opacity))
        .id(displayText)
      
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .floating()
    .mask(Capsule(style: .continuous).fill(.black))
    .frame(maxWidth: .infinity)
    .compositingGroup()
    .scaleEffect(1)
    .offset(y: !loader.showing ? 75 : -62)
  }
}

@MainActor
@Observable
final class GlobalLoaderModel {
  var loadingText: String?
  var showing = false
  private var generation = 0

  func start(_ str: String) {
    generation += 1
    loadingText = str
    showing = true
  }

  func dismiss() {
    let dismissGeneration = generation
    let heavy = UIImpactFeedbackGenerator(style: .heavy)
    let soft = UIImpactFeedbackGenerator(style: .rigid)
    heavy.prepare()
    soft.prepare()
    withAnimation(.easeOut) {
      loadingText = nil
    }
    heavy.impactOccurred()
    doThisAfter(0.2) {
      soft.impactOccurred()
    }
    doThisAfter(0.75) {
      Task { @MainActor in
        guard self.generation == dismissGeneration else { return }
        withAnimation(spring) {
          self.showing = false
        }
      }
    }
  }
}

struct GlobalLoaderProviderModifier: ViewModifier {
  @State private var loader = GlobalLoaderModel()

  func body(content: Content) -> some View {
    content
      .environment(loader)
      .overlay(
        GeometryReader { geo in
          GlobalLoaderView(loader: loader)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
          .ignoresSafeArea(.keyboard)
        , alignment: .bottom
      )
  }
}

extension View {
  func globalLoaderProvider() -> some View {
    self
      .modifier(GlobalLoaderProviderModifier())
  }
}
