import Foundation

/// The three PRD §6 budgets that cannot be measured from outside the process:
/// cold launch to menu bar ready, hotkey to window visible, and the search round
/// trip. `time` on the process measures the wrong thing for all three.
///
/// Off unless `CLIPFLOW_TIMING=1`. A menu bar app logging two lines every time
/// its window opens is noise, and these numbers are only wanted while someone is
/// measuring — but they have to be *in* the shipping binary, because a number
/// taken from a debug build is not the number the user gets.
enum Timing {
  static let enabled = ProcessInfo.processInfo.environment["CLIPFLOW_TIMING"] == "1"

  /// Wall clock at `exec`, read from the kernel's process table rather than
  /// taken on the first line of `main`. Everything expensive about a cold launch
  /// — dyld, the Swift runtime, AppKit and SwiftUI — happens before `main` runs,
  /// so timing from there would report a launch that never happened.
  static let processStart: Date = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let started = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
  }()

  static func sinceLaunch(_ label: String) {
    guard enabled else { return }
    NSLog("ClipFlow timing: \(label) \(format(Date().timeIntervalSince(processStart)))")
  }

  static func since(_ start: ContinuousClock.Instant, _ label: String) {
    guard enabled else { return }
    NSLog("ClipFlow timing: \(label) \(format(seconds(ContinuousClock.now - start)))")
  }

  static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  static func format(_ seconds: Double) -> String {
    String(format: "%.1f ms", seconds * 1000)
  }
}
