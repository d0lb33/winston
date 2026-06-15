//
//  LightBox.swift
//  winston
//
//  Created by Igor Marcossi on 28/06/23.
//

import SwiftUI
import NukeUI
import Defaults

private let SPACING = 24.0

struct LightBoxImage: View {
  var postTitle: String? = nil
  var badgeKit: BadgeKit? = nil
  var avatarImageRequest: ImageRequest? = nil
  var markAsSeen: (() async -> ())? = nil
  var i: Int
  var imagesArr: [ImgExtracted]
  var doLiveText: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var appearBlack = false
  // Content is visible immediately so the zoom transition morphs the real image rather than
  // fading it in (the fade was for the old modal presentation).
  @State private var appearContent = true
  @State private var dragOffset: CGSize?
  @State private var drag: CGSize = .zero
  @State private var xPos: CGFloat = 0
  @State private var dragAxis: Axis?
  @State private var activeIndex = 0
  @State private var loading = false
  @State private var done = false
  @State private var showOverlay = true
  @State private var isPinching: Bool = false
  @State private var isZoomed: Bool = false
  @State private var scale: CGFloat = 1.0
  @State private var gifPlaybackState: GIFPlaybackState?
  @State private var isGifScrubbing = false
  @State private var gifScrubStartProgress: Double?
  @State private var gifScrubProgressRequest: Double?
  
  private enum Axis {
    case horizontal
    case vertical
  }

  private var activeImageURL: URL? {
    guard imagesArr.indices.contains(activeIndex) else { return nil }
    return imagesArr[activeIndex].url
  }

  private var activeGIFPlaybackState: GIFPlaybackState? {
    guard
      isActiveImageGIF,
      gifPlaybackState?.url == activeImageURL
    else {
      return nil
    }
    return gifPlaybackState
  }

  private var isActiveImageGIF: Bool {
    activeImageURL?.pathExtension.lowercased() == "gif"
  }

  func toggleOverlay() {
    withAnimation(.easeOut(duration: 0.2)) {
      showOverlay.toggle()
    }
  }

  private func closeViewer() {
    dismiss()
  }
  
  var body: some View {
    let interpolate = interpolatorBuilder([0, 100], value: abs(drag.height))
    GeometryReader { proxy in
      let viewportSize = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
      let pageWidth = viewportSize.width

      Group {
        if imagesArr.isEmpty {
          Color.black
            .onAppear { closeViewer() }
        } else {
          HStack(spacing: SPACING) {
            ForEach(Array(imagesArr.enumerated()), id: \.element.id) { index, img in
              let selected = index == activeIndex
              LightBoxElementView(
                el: img,
                onTap: toggleOverlay,
                doLiveText: doLiveText,
                isActive: selected,
                isPinching: $isPinching,
                isZoomed: $isZoomed,
                zoomScale: $scale,
                gifPlaybackState: $gifPlaybackState,
                isGifScrubbing: $isGifScrubbing,
                gifScrubProgressRequest: selected ? gifScrubProgressRequest : nil,
                viewportSize: viewportSize
              )
                .allowsHitTesting(selected)
                .scaleEffect(!selected ? 1 : interpolate([1, 0.9], true))
                .blur(radius: selected && loading ? 24 : 0)
                .offset(x: !selected ? 0 : dragAxis == .vertical ? drag.width : 0, y: !selected ? 0 : dragAxis == .vertical ? drag.height : 0)
            }
          }
          .fixedSize(horizontal: true, vertical: false)
        }
      }
      .offset(x: xPos + (dragAxis == .horizontal ? drag.width : 0))
      .frame(width: viewportSize.width, height: viewportSize.height, alignment: .leading)
      .highPriorityGesture(
        isActiveImageGIF && !isZoomed && scale <= 1.01
        ? DragGesture(minimumDistance: 10)
          .onChanged { val in
            if dragAxis == nil || dragOffset == nil {
              dragOffset = val.translation
              if abs(val.translation.width) > abs(val.translation.height) {
                dragAxis = .horizontal
              } else if abs(val.translation.height) > abs(val.translation.width) {
                dragAxis = .vertical
              }
            }

            guard let dragAxis else { return }

            if dragAxis == .horizontal {
              let startProgress = gifScrubStartProgress ?? activeGIFPlaybackState?.progress ?? 0
              gifScrubStartProgress = startProgress
              isGifScrubbing = true
              gifScrubProgressRequest = min(max(startProgress + Double(val.translation.width / pageWidth), 0), 1)
            } else if let dragOffset {
              var transaction = Transaction()
              transaction.isContinuous = true
              transaction.animation = .interpolatingSpring(stiffness: 1000, damping: 100, initialVelocity: 0)
              withTransaction(transaction) {
                drag = val.translation - dragOffset
              }
            }
          }
          .onEnded { val in
            if dragAxis == .vertical {
              let shouldClose = abs(val.translation.width) > 100 || abs(val.translation.height) > 100

              if shouldClose {
                withAnimation(.easeOut) {
                  appearBlack = false
                }
              }
              withAnimation(.interpolatingSpring(stiffness: 200, damping: 20, initialVelocity: 0)) {
                drag = .zero
                dragAxis = nil
                dragOffset = nil
                if shouldClose {
                  closeViewer()
                }
              }
            } else {
              dragAxis = nil
              dragOffset = nil
            }

            isGifScrubbing = false
            gifScrubStartProgress = nil
            gifScrubProgressRequest = nil
          }
        : nil
      )
      .highPriorityGesture(
        isZoomed || scale > 1.01 || isActiveImageGIF || isGifScrubbing
        ? nil
        : DragGesture(minimumDistance: 20)
          .onChanged { val in
            
            if dragAxis == nil || dragOffset == nil {
              dragOffset = val.translation
              if abs(val.predictedEndTranslation.width) > abs(val.predictedEndTranslation.height) {
                dragAxis = .horizontal
              } else if abs(val.predictedEndTranslation.width) < abs(val.predictedEndTranslation.height) {
                dragAxis = .vertical
              }
            }

            if let dragAxis = dragAxis, let dragOffset = dragOffset {
              var transaction = Transaction()
              transaction.isContinuous = true
              transaction.animation = .interpolatingSpring(stiffness: 1000, damping: 100, initialVelocity: 0)

              var endPos = val.translation
              if dragAxis == .horizontal {
                endPos.height = 0
              }
              withTransaction(transaction) {
                drag = endPos - dragOffset
              }
            }
          }
          .onEnded { val in
            if dragAxis == .horizontal {
              let predictedEnd = val.predictedEndTranslation.width - (dragOffset?.width ?? 0)
              drag = .zero
              xPos += val.translation.width - (dragOffset?.width ?? 0)
              dragOffset = nil
              let newActiveIndex = min(imagesArr.count - 1, max(0, activeIndex + (predictedEnd < -(pageWidth / 2) ? 1 : predictedEnd > pageWidth / 2 ? -1 : 0)))
              let finalXPos = -(CGFloat(newActiveIndex) * (pageWidth + SPACING))
              let distance = abs(finalXPos - xPos)
              activeIndex = newActiveIndex
              isZoomed = false
              scale = 1
              var initialVel = distance > 1 ? abs(predictedEnd / distance) : 0
              initialVel = initialVel < 3.75 ? 0 : initialVel * 2
              withAnimation(.interpolatingSpring(stiffness: 150, damping: 17, initialVelocity: initialVel)) {
                xPos = finalXPos
                dragAxis = nil
              }
            } else {
              let shouldClose = abs(val.translation.width) > 100 || abs(val.translation.height) > 100

              if shouldClose {
                withAnimation(.easeOut) {
                  appearBlack = false
                }
              }
              withAnimation(.interpolatingSpring(stiffness: 200, damping: 20, initialVelocity: 0)) {
                drag = .zero
                dragAxis = nil
                if shouldClose {
                  closeViewer()
                }
              }
            }
          }
      )
      .overlay {
        if let postTitle = postTitle, let badgeKit = badgeKit {
          LightBoxOverlay(postTitle: postTitle, badgeKit: badgeKit, avatarImageRequest: avatarImageRequest, opacity: !showOverlay || isPinching ? 0 : interpolate([1, 0], false), imagesArr: imagesArr, activeIndex: activeIndex, loading: $loading, done: $done)
        }
      }
      .overlay(alignment: .bottom) {
        if let activeGIFPlaybackState {
          GIFPlaybackProgressView(state: activeGIFPlaybackState)
            .padding(.horizontal, 24)
            .padding(.bottom, 96)
            .opacity(isPinching ? 0 : 1)
            .transition(.opacity)
        }
      }
      .background(
        !appearBlack
        ? nil
        : Color.black
          .opacity(interpolate([1, 0], false))
          .onTapGesture {
            withAnimation(.easeOut) {
              appearBlack = false
            }
          }
          .allowsHitTesting(appearBlack)
          .transition(.opacity)
      )
      .overlay {
        if loading || done {
          ZStack {
            if done {
              Image(systemName: "checkmark.circle.fill")
                .fontSize(40)
                .transition(.scaleAndBlur)
            } else {
              ProgressView()
                .transition(.scaleAndBlur)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.black.opacity(0.25))
        }
      }
      .ignoresSafeArea(edges: .all)
      .compositingGroup()
      .opacity(appearContent ? 1 : 0)
      .onChange(of: done) { _, newValue in
        if newValue {
          doThisAfter(0.5) {
            withAnimation(spring) {
              done = false
              loading = false
            }
          }
        }
      }
      .onChange(of: activeIndex) {
        gifPlaybackState = nil
        isGifScrubbing = false
        gifScrubStartProgress = nil
        gifScrubProgressRequest = nil
      }
      .onChange(of: viewportSize) {
        xPos = -CGFloat(activeIndex) * (pageWidth + SPACING)
      }
      .onAppear {
        if let markAsSeen { Task(priority: .background) { await markAsSeen() } }
        let safeIndex = min(max(i, 0), max(imagesArr.count - 1, 0))
        xPos = -CGFloat(safeIndex) * (pageWidth + SPACING)
        activeIndex = safeIndex
        doThisAfter(0.0) {
          withAnimation(.easeOut) {
            appearContent = true
            appearBlack = true
          }
        }
      }
      .transition(.opacity)
    }
  }
}

private struct GIFPlaybackProgressView: View {
  let state: GIFPlaybackState

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.white.opacity(0.24))
        Capsule(style: .continuous)
          .fill(.white.opacity(0.92))
          .frame(width: max(6, proxy.size.width * min(max(state.progress, 0), 1)))
      }
    }
    .frame(height: 5)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Capsule(style: .continuous).fill(.black.opacity(0.45)))
    .allowsHitTesting(false)
  }
}
