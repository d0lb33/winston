//
//  PerformanceDiagnostics.swift
//  winston
//
//  UI/runtime performance instrumentation: MetricKit payload capture and a
//  lightweight frame-hitch monitor for the Debug HUD.
//

import Foundation
import MetricKit
import QuartzCore
import UIKit

/// Subscribes to MetricKit and records the headline numbers (launch time,
/// hang rate, crash diagnostics) into AppDiagnostics. Full payloads are
/// written next to the diagnostic logs so they ride along in exports.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
  static let shared = MetricKitSubscriber()

  func start() {
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      var metadata: [String: String] = [
        "from": ISO8601DateFormatter().string(from: payload.timeStampBegin),
        "to": ISO8601DateFormatter().string(from: payload.timeStampEnd),
      ]
      if let launch = payload.applicationLaunchMetrics {
        metadata["launchTimeToFirstDrawAvg"] = histogramAverage(launch.histogrammedTimeToFirstDraw)
      }
      if let responsiveness = payload.applicationResponsivenessMetrics {
        metadata["hangTimeAvg"] = histogramAverage(responsiveness.histogrammedApplicationHangTime)
      }
      if let exit = payload.applicationExitMetrics {
        metadata["fgAbnormalExits"] = "\(exit.foregroundExitData.cumulativeAbnormalExitCount)"
        metadata["fgMemoryKills"] = "\(exit.foregroundExitData.cumulativeMemoryResourceLimitExitCount)"
      }
      AppDiagnostics.asyncRecord(.info, category: "perf.metrickit", message: "MetricKit metrics payload received", metadata: metadata)
      Self.persist(payload.jsonRepresentation(), prefix: "metrickit-metrics")
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      let crashes = payload.crashDiagnostics?.count ?? 0
      let hangs = payload.hangDiagnostics?.count ?? 0
      let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
      AppDiagnostics.asyncRecord(
        crashes > 0 ? .error : .warning,
        category: "perf.metrickit",
        message: "MetricKit diagnostics payload received",
        metadata: ["crashes": "\(crashes)", "hangs": "\(hangs)", "cpuExceptions": "\(cpuExceptions)"]
      )
      Self.persist(payload.jsonRepresentation(), prefix: "metrickit-diagnostics")
    }
  }

  private static func persist(_ data: Data, prefix: String) {
    Task { @MainActor in
      let directory = AppDiagnostics.shared.logDirectory
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let url = directory.appendingPathComponent("\(prefix)-\(stamp).json")
      try? data.write(to: url)
    }
  }
}

/// Rough weighted average across a MetricKit histogram's buckets — enough for
/// a one-line summary. Free function so the unit type is bound at the call
/// site (an extension on the generic ObjC class can't read its parameter at
/// runtime).
private func histogramAverage<U: Unit>(_ histogram: MXHistogram<U>) -> String {
  var total = 0.0
  var count = 0.0
  let enumerator = histogram.bucketEnumerator
  while let bucket = enumerator.nextObject() as? MXHistogramBucket<U> {
    let mid = (bucket.bucketStart.value + bucket.bucketEnd.value) / 2
    total += mid * Double(bucket.bucketCount)
    count += Double(bucket.bucketCount)
  }
  guard count > 0 else { return "n/a" }
  return String(format: "%.1f", total / count)
}

/// DEBUG-only switch for SwiftUI render-cause logging (`Self._printChanges()`)
/// in hot views. Output goes to the Xcode console/Console.app; the flag lives
/// in UserDefaults so the Diagnostics panel can toggle it at runtime.
enum RenderDiagnostics {
  static let defaultsKey = "diagnostics.printChanges"

  @inline(__always)
  static func logIfEnabled(_ log: () -> Void) {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: defaultsKey) { log() }
    #endif
  }
}

/// Counts dropped-frame hitches via CADisplayLink and exposes a rolling
/// hitches-per-minute figure for the Debug HUD. Only runs while the HUD is
/// visible — it costs a display-link callback per frame.
@MainActor
final class FrameHitchMonitor: ObservableObject {
  static let shared = FrameHitchMonitor()

  @Published private(set) var hitchesPerMinute: Int = 0

  private var displayLink: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0
  private var hitchTimestamps: [CFTimeInterval] = []
  private var lastPublish: CFTimeInterval = 0

  func start() {
    guard displayLink == nil else { return }
    lastTimestamp = 0
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    hitchTimestamps.removeAll()
    hitchesPerMinute = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    defer { lastTimestamp = link.timestamp }
    guard lastTimestamp > 0 else { return }
    let actual = link.timestamp - lastTimestamp
    // A hitch = a frame that took at least 2.5x its budget (and isn't just
    // the app coming back from the background).
    if actual > link.duration * 2.5, actual < 2 {
      hitchTimestamps.append(link.timestamp)
    }
    if link.timestamp - lastPublish >= 1 {
      lastPublish = link.timestamp
      let cutoff = link.timestamp - 60
      hitchTimestamps.removeAll { $0 < cutoff }
      let value = hitchTimestamps.count
      if value != hitchesPerMinute {
        hitchesPerMinute = value
      }
    }
  }
}
