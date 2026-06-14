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
import os

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
    ScrollPerfProbe.shared.enabled = true
    MainThreadSampler.shared.start()
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    ScrollPerfProbe.shared.enabled = false
    _ = ScrollPerfProbe.shared.drain()
    MainThreadSampler.shared.stop()
    displayLink?.invalidate()
    displayLink = nil
    hitchTimestamps.removeAll()
    hitchesPerMinute = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    defer { lastTimestamp = link.timestamp }
    // Let the stall sampler know the main thread is alive (it samples when this
    // heartbeat goes stale, i.e. the main thread is blocked).
    MainThreadSampler.shared.heartbeat()
    // Reset the per-frame attribution window every tick; capture what happened
    // during the frame we just finished (it's drained whether or not it hitched).
    let activity = ScrollPerfProbe.shared.drain()
    guard lastTimestamp > 0 else { return }
    let actual = link.timestamp - lastTimestamp
    // A hitch = a frame that took at least 2.5x its budget (and isn't just
    // the app coming back from the background).
    if actual > link.duration * 2.5, actual < 2 {
      hitchTimestamps.append(link.timestamp)
      var metadata = activity ?? [:]
      InlineVideoCoordinator.shared.diagnosticMetadata().forEach { key, value in
        metadata[key] = value
      }
      metadata["frameMs"] = String(format: "%.1f", actual * 1000)
      metadata["budgetMs"] = String(format: "%.1f", link.duration * 1000)
      if let stack = MainThreadSampler.shared.drainTopSamples() {
        metadata["stack"] = stack
      }
      AppDiagnostics.asyncRecord(
        .warning,
        category: "perf.hitch",
        message: "Frame hitch \(Int(actual * 1000))ms",
        metadata: metadata
      )
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

/// Lightweight, lock-guarded attribution probe for scroll hitches. Hot paths call
/// `bump`/`measure`; `FrameHitchMonitor` drains the accumulated counts/timings each
/// frame and logs them alongside any hitch. Active only while the Debug HUD is on,
/// so it costs nothing in normal use.
final class ScrollPerfProbe {
  static let shared = ScrollPerfProbe()

  /// Toggled with `FrameHitchMonitor.start()/stop()`. When false, all calls early-out.
  var enabled = false

  private var lock = os_unfair_lock_s()
  private var counts: [String: Int] = [:]
  private var nanos: [String: UInt64] = [:]

  /// Record one occurrence of `category`, optionally with elapsed nanoseconds.
  func bump(_ category: String, nanos addNanos: UInt64 = 0) {
    guard enabled else { return }
    os_unfair_lock_lock(&lock)
    counts[category, default: 0] += 1
    if addNanos > 0 { nanos[category, default: 0] += addNanos }
    os_unfair_lock_unlock(&lock)
  }

  /// Time `work` and attribute its duration + one count to `category`.
  @inline(__always)
  func measure<T>(_ category: String, _ work: () throws -> T) rethrows -> T {
    guard enabled else { return try work() }
    let start = DispatchTime.now().uptimeNanoseconds
    defer { bump(category, nanos: DispatchTime.now().uptimeNanoseconds - start) }
    return try work()
  }

  /// Snapshot and clear the window. Returns "count×" or "count×/ms" per category.
  func drain() -> [String: String]? {
    os_unfair_lock_lock(&lock)
    defer {
      counts.removeAll(keepingCapacity: true)
      nanos.removeAll(keepingCapacity: true)
      os_unfair_lock_unlock(&lock)
    }
    guard !counts.isEmpty else { return nil }
    var result: [String: String] = [:]
    for (key, count) in counts {
      let ms = Double(nanos[key] ?? 0) / 1_000_000
      result[key] = ms >= 0.1 ? "\(count)x/\(String(format: "%.1f", ms))ms" : "\(count)x"
    }
    return result
  }
}

/// Poor-man's sampling profiler for the main thread. A background timer watches a
/// heartbeat that `FrameHitchMonitor` bumps every frame; when the heartbeat goes
/// stale (the main thread is blocked), it suspends the main thread just long enough
/// to read its program counter, then symbolicates it with `dladdr`. The accumulated
/// "which binary/function was the main thread stuck in" histogram is attached to each
/// logged hitch — revealing costs that the counter probe can't see (SwiftUI layout,
/// image decode, CoreAnimation, AVFoundation).
///
/// Active only while the Debug HUD is on. Only ever inspects this process's own main
/// thread, and never allocates while the thread is suspended (dladdr runs after resume).
final class MainThreadSampler {
  static let shared = MainThreadSampler()

  private let queue = DispatchQueue(label: "lo.cafe.winston.mainthread-sampler", qos: .userInteractive)
  private var timer: DispatchSourceTimer?
  private var mainThread: thread_t = 0
  private var lastHeartbeatNs: UInt64 = 0
  private let stallThresholdNs: UInt64 = 24_000_000   // ~1.5 frames @ 60Hz
  private let runawayNs: UInt64 = 2_000_000_000        // ignore background/breakpoint gaps
  private let lock = NSLock()
  private var samples: [String: Int] = [:]

  private func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

  /// Must be called on the main thread (it captures the main mach thread port).
  func start() {
    mainThread = pthread_mach_thread_np(pthread_self())
    lastHeartbeatNs = nowNs()
    lock.lock(); samples.removeAll(); lock.unlock()
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
    t.setEventHandler { [weak self] in self?.poll() }
    timer = t
    t.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
    lock.lock(); samples.removeAll(); lock.unlock()
  }

  /// Called every frame from the main thread.
  func heartbeat() { lastHeartbeatNs = nowNs() }

  private func poll() {
    let elapsed = nowNs() &- lastHeartbeatNs
    guard elapsed > stallThresholdNs, elapsed < runawayNs else { return }
    sampleMainThread()
  }

  private func sampleMainThread() {
    #if arch(arm64)
    guard mainThread != 0 else { return }
    guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
    var state = arm_thread_state64_t()
    var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
    let kr = withUnsafeMutablePointer(to: &state) { statePtr in
      statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { intPtr in
        thread_get_state(mainThread, ARM_THREAD_STATE64, intPtr, &count)
      }
    }
    // Walk the frame-pointer chain while suspended (the stack is stable). vm_read_overwrite
    // is bounds-checked, so a bad pointer returns an error instead of crashing; only memory
    // reads happen here — no allocation. The mask strips pointer-auth / TBI bits.
    let mask: UInt = 0x0000_00FF_FFFF_FFFF
    var addresses: [UInt] = []
    if kr == KERN_SUCCESS {
      addresses.append(UInt(state.__pc) & mask)
      let lr = UInt(state.__lr) & mask
      if lr > 0x1000 { addresses.append(lr) }
      var fp = UInt(state.__fp)
      var depth = 0
      while fp > 0x1000, depth < 32, addresses.count < 24 {
        guard let savedFP = Self.readWord(fp), let savedLR = Self.readWord(fp &+ 8) else { break }
        let ret = savedLR & mask
        if ret > 0x1000 { addresses.append(ret) }
        if savedFP <= fp { break }   // caller frame is higher on the stack
        fp = savedFP
        depth += 1
      }
    }
    // Resume BEFORE symbolicating (dladdr can lock/allocate) to avoid deadlock.
    thread_resume(mainThread)
    guard !addresses.isEmpty else { return }

    var frames: [String] = []
    for addr in addresses {
      var info = Dl_info()
      var label = "0x\(String(addr, radix: 16))"
      if let ptr = UnsafeRawPointer(bitPattern: addr), dladdr(ptr, &info) != 0 {
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        label = info.dli_sname.map { "\(image)`\(String(cString: $0))" } ?? image
      }
      frames.append(label)
      if frames.count >= 6 { break }
    }
    let signature = frames.joined(separator: " < ")
    lock.lock(); samples[signature, default: 0] += 1; lock.unlock()
    #endif
  }

  /// Bounds-checked single-word read of this process's memory (won't crash on a bad pointer).
  private static func readWord(_ address: UInt) -> UInt? {
    var value: UInt = 0
    var outCount: vm_size_t = 0
    let kr = withUnsafeMutablePointer(to: &value) { dst in
      vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        vm_size_t(MemoryLayout<UInt>.size),
        vm_address_t(UInt(bitPattern: dst)),
        &outCount
      )
    }
    return (kr == KERN_SUCCESS && outCount == vm_size_t(MemoryLayout<UInt>.size)) ? value : nil
  }

  /// Top sampled main-thread locations since the last drain, as a compact string.
  func drainTopSamples(_ maxCount: Int = 6) -> String? {
    lock.lock()
    defer { samples.removeAll(keepingCapacity: true); lock.unlock() }
    guard !samples.isEmpty else { return nil }
    return samples.sorted { $0.value > $1.value }
      .prefix(maxCount)
      .map { "\($0.key)×\($0.value)" }
      .joined(separator: " | ")
  }
}
