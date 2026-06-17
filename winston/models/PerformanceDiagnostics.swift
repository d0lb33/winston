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
import SwiftUI
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

enum FeedMediaDiagnostics {
  static let disableAuroraFeedMediaKey = "diagnostics.disableAuroraFeedMedia"

  static var isAuroraFeedMediaDisabled: Bool {
    UserDefaults.standard.bool(forKey: disableAuroraFeedMediaKey)
  }
}

enum TapTargetDiagnostics {
  static let defaultsKey = "diagnostics.showTapTargets"
}

private struct TapTargetDiagnosticModifier: ViewModifier {
  @AppStorage(TapTargetDiagnostics.defaultsKey) private var enabled = false
  let label: String
  let color: Color

  func body(content: Content) -> some View {
    content.overlay(alignment: .topLeading) {
      if enabled {
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(0.10))
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(color.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
          Text(label)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.92), in: Capsule())
            .padding(2)
        }
        .allowsHitTesting(false)
      }
    }
  }
}

extension View {
  func diagnosticTapTarget(_ label: String, color: Color = .pink) -> some View {
    modifier(TapTargetDiagnosticModifier(label: label, color: color))
  }
}

/// Counts dropped-frame hitches via CADisplayLink and exposes a rolling
/// hitches-per-minute figure for diagnostics. Only runs while scroll/hitch
/// diagnostics are enabled — it costs a display-link callback per frame.
@MainActor
final class FrameHitchMonitor: ObservableObject {
  static let shared = FrameHitchMonitor()

  @Published private(set) var hitchesPerMinute: Int = 0

  private var displayLink: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0
  private var hitchTimestamps: [CFTimeInterval] = []
  private var lastPublish: CFTimeInterval = 0

  // Per-second scroll-activity accumulation. The sim's display link usually runs at
  // 60Hz, so the 2.5x-budget hitch test (~42ms) misses 120fps jank entirely. This
  // window aggregates ScrollPerfProbe work + budget-relative frame buckets every
  // second of activity, independent of whether any single frame crossed the hitch
  // threshold — so attribution survives even on a fast host that never drops a frame.
  private var lastActivityDump: CFTimeInterval = 0
  private var activityCounts: [String: Int] = [:]
  private var activityNanos: [String: UInt64] = [:]
  private var windowFrames = 0
  private var windowMildJank = 0   // frames > 1.5x budget
  private var windowHitches = 0    // frames > 2.5x budget
  private var windowMaxFrameMs: Double = 0

  func start() {
    guard displayLink == nil else { return }
    lastTimestamp = 0
    lastActivityDump = 0
    resetActivityWindow()
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
    resetActivityWindow()
    hitchesPerMinute = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    defer { lastTimestamp = link.timestamp }
    // Let the stall sampler know the main thread is alive (it samples when this
    // heartbeat goes stale, i.e. the main thread is blocked).
    MainThreadSampler.shared.heartbeat()
    // Drain this frame's attribution. Accumulate it into the 1s window AND keep this
    // frame's slice for a per-frame hitch record below.
    let frameRaw = ScrollPerfProbe.shared.drainRaw()
    if let frameRaw {
      for (key, count) in frameRaw.counts { activityCounts[key, default: 0] += count }
      for (key, ns) in frameRaw.nanos { activityNanos[key, default: 0] += ns }
    }
    guard lastTimestamp > 0 else {
      lastActivityDump = link.timestamp
      return
    }
    let actual = link.timestamp - lastTimestamp
    if actual < 2 {  // ignore background/breakpoint gaps
      windowFrames += 1
      if actual > link.duration * 1.5 { windowMildJank += 1 }
      windowMaxFrameMs = max(windowMaxFrameMs, actual * 1000)
    }
    // A hitch = a frame that took at least 2.5x its budget (and isn't just
    // the app coming back from the background).
    if actual > link.duration * 2.5, actual < 2 {
      windowHitches += 1
      hitchTimestamps.append(link.timestamp)
      var metadata = frameRaw.map { ScrollPerfProbe.format(counts: $0.counts, nanos: $0.nanos) } ?? [:]
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
    if link.timestamp - lastActivityDump >= 1 {
      lastActivityDump = link.timestamp
      emitScrollActivity(budget: link.duration)
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

  /// Emit one `perf.scrollactivity` record summarizing the last second — but only if
  /// real work happened (so an idle feed stays silent). Carries per-category work
  /// counts/ms, frame-jank buckets relative to the live display budget, and any
  /// main-thread stall stacks sampled during the window.
  private func emitScrollActivity(budget: CFTimeInterval) {
    defer { resetActivityWindow() }
    guard !activityCounts.isEmpty else { return }
    var metadata = ScrollPerfProbe.format(counts: activityCounts, nanos: activityNanos)
    metadata["windowFrames"] = "\(windowFrames)"
    metadata["mildJank"] = "\(windowMildJank)"      // > 1.5x budget
    metadata["hitches"] = "\(windowHitches)"        // > 2.5x budget
    metadata["maxFrameMs"] = String(format: "%.1f", windowMaxFrameMs)
    metadata["budgetMs"] = String(format: "%.1f", budget * 1000)
    InlineVideoCoordinator.shared.diagnosticMetadata().forEach { key, value in
      metadata[key] = value
    }
    if let stack = MainThreadSampler.shared.drainTopSamples() {
      metadata["stack"] = stack
    }
    AppDiagnostics.asyncRecord(
      .info,
      category: "perf.scrollactivity",
      message: "Scroll activity (1s): \(windowFrames) frames, \(windowMildJank) mild, \(windowHitches) hitch, max \(Int(windowMaxFrameMs))ms",
      metadata: metadata
    )
  }

  private func resetActivityWindow() {
    activityCounts.removeAll(keepingCapacity: true)
    activityNanos.removeAll(keepingCapacity: true)
    windowFrames = 0
    windowMildJank = 0
    windowHitches = 0
    windowMaxFrameMs = 0
  }
}

/// Lightweight, lock-guarded attribution probe for scroll hitches. Hot paths call
/// `bump`/`measure`; `FrameHitchMonitor` drains the accumulated counts/timings each
/// frame and logs them alongside any hitch. Active only while scroll/hitch
/// diagnostics are enabled, so it costs nothing in normal use.
final class ScrollPerfProbe {
  static let shared = ScrollPerfProbe()

  /// Toggled with `FrameHitchMonitor.start()/stop()`. When false, all calls early-out.
  var enabled = false

  var isEnabled: Bool { enabled }

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
    guard let raw = drainRaw() else { return nil }
    return Self.format(counts: raw.counts, nanos: raw.nanos)
  }

  /// Snapshot and clear the window as raw numbers, so callers can accumulate across
  /// frames (the per-second scroll-activity dump) without losing precision to formatting.
  func drainRaw() -> (counts: [String: Int], nanos: [String: UInt64])? {
    os_unfair_lock_lock(&lock)
    defer {
      counts.removeAll(keepingCapacity: true)
      nanos.removeAll(keepingCapacity: true)
      os_unfair_lock_unlock(&lock)
    }
    guard !counts.isEmpty else { return nil }
    return (counts, nanos)
  }

  /// Render accumulated counts/nanos into "count×" / "count×/ms" strings.
  static func format(counts: [String: Int], nanos: [String: UInt64]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, count) in counts {
      let ms = Double(nanos[key] ?? 0) / 1_000_000
      result[key] = ms >= 0.1 ? "\(count)x/\(String(format: "%.1f", ms))ms" : "\(count)x"
    }
    return result
  }
}

/// Shared helpers for targeted scroll diagnostics. These are gated by
/// `ScrollPerfProbe.enabled`, so normal app use does not emit extra logs or do
/// metadata work. Turn on scroll/hitch diagnostics to collect them.
enum ScrollPerfDiagnostics {
  static func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  static func bump(_ category: String, nanos: UInt64 = 0) {
    ScrollPerfProbe.shared.bump(category, nanos: nanos)
  }

  @discardableResult
  @inline(__always)
  static func measure<T>(
    _ category: String,
    slowThresholdMs: Double? = nil,
    slowMessage: String? = nil,
    metadata: @autoclosure () -> [String: String] = [:],
    _ work: () throws -> T
  ) rethrows -> T {
    guard ScrollPerfProbe.shared.isEnabled else { return try work() }
    let start = now()
    defer {
      let elapsed = now() - start
      ScrollPerfProbe.shared.bump(category, nanos: elapsed)
      if let slowThresholdMs {
        recordDuration(
          category: category,
          message: slowMessage ?? category,
          elapsedNanos: elapsed,
          thresholdMs: slowThresholdMs,
          metadata: metadata()
        )
      }
    }
    return try work()
  }

  static func event(
    _ message: String,
    category: String = "perf.scroll.lifecycle",
    metadata: [String: String] = [:]
  ) {
    guard ScrollPerfProbe.shared.isEnabled else { return }
    AppDiagnostics.asyncRecord(.info, category: category, message: message, metadata: metadata)
  }

  static func recordDuration(
    category: String,
    message: String,
    elapsedNanos: UInt64,
    thresholdMs: Double,
    metadata: [String: String] = [:]
  ) {
    guard ScrollPerfProbe.shared.isEnabled else { return }
    let elapsedMs = Double(elapsedNanos) / 1_000_000
    guard elapsedMs >= thresholdMs else { return }
    var combined = metadata
    combined["elapsedMs"] = String(format: "%.1f", elapsedMs)
    AppDiagnostics.asyncRecord(
      elapsedMs >= thresholdMs * 2 ? .warning : .info,
      category: "perf.scroll.slow",
      message: message,
      metadata: combined.merging(["probe": category]) { current, _ in current }
    )
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
/// Active only while scroll/hitch diagnostics are enabled. Only ever inspects this
/// process's own main thread, and never allocates while the thread is suspended
/// (dladdr runs after resume).
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

    // Symbolicate deeper than the displayed depth: demangle/metadata-cache storms can
    // fill 4-6 consecutive frames of pure Swift-runtime internals, hiding the SwiftUI /
    // app caller that actually triggered the work. We collapse runs of those internals
    // into one "«swiftrt»" token so the informative caller still surfaces in 6 slots.
    var rawFrames: [String] = []
    for addr in addresses {
      var info = Dl_info()
      var label = "0x\(String(addr, radix: 16))"
      if let ptr = UnsafeRawPointer(bitPattern: addr), dladdr(ptr, &info) != 0 {
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        label = info.dli_sname.map { "\(image)`\(String(cString: $0))" } ?? image
      }
      rawFrames.append(label)
      if rawFrames.count >= 16 { break }
    }
    var frames: [String] = []
    var lastWasRuntime = false
    for label in rawFrames {
      if Self.isSwiftRuntimeNoise(label) {
        if !lastWasRuntime { frames.append("«swiftrt»") }
        lastWasRuntime = true
      } else {
        frames.append(label)
        lastWasRuntime = false
      }
      if frames.count >= 6 { break }
    }
    let signature = frames.joined(separator: " < ")
    lock.lock(); samples[signature, default: 0] += 1; lock.unlock()
    #endif
  }

  /// True for Swift-runtime internals that recur in metadata-instantiation / demangle /
  /// refcount storms — collapsed in the stack signature so the real caller is visible.
  private static func isSwiftRuntimeNoise(_ s: String) -> Bool {
    s.contains("Demangle") || s.contains("MetadataCache") || s.contains("getTypeByMangledName")
      || s.contains("GenericCacheEntry") || s.contains("ConcurrentReadableHashMap")
      || s.contains("LockingConcurrentMap") || s.contains("WitnessTable")
      || s.contains("swift_slowAlloc") || s.contains("_xzm_") || s.contains("RefCounts")
      || s.contains("swift_release") || s.contains("swift_retain") || s.contains("swift_bridgeObjectRelease")
      || s.contains("swift_getType") || s.contains("swift_checkMetadataState")
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
