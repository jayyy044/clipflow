import AppKit
import GRDB
import Observation
import SwiftUI

/// Live view of the items table. GRDB pushes a new array whenever the table
/// changes, so nothing has to poll or manually refresh.
@Observable
final class History {
  static let shared = History()

  var items: [Item] = []
  private var task: Task<Void, Never>?

  private init() {
    let observation = ValueObservation.tracking { db in
      try Item.recent().fetchAll(db)
    }
    task = Task { @MainActor [weak self] in
      do {
        for try await items in observation.values(in: Database.shared) {
          self?.items = items
        }
      } catch {
        NSLog("ClipFlow: history observation stopped: \(error)")
      }
    }
  }
}

struct HistoryView: View {
  var onClose: () -> Void

  @State private var history = History.shared
  @State private var selection: Int64?

  var body: some View {
    VStack(spacing: 0) {
      if history.items.isEmpty {
        empty
      } else {
        list
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .background(.thinMaterial)
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
  }

  private var list: some View {
    // `selection` plus a focused List is what makes the arrow keys work; there
    // is no manual key handling here.
    List(history.items, selection: $selection) { item in
      ItemRow(item: item)
        .tag(item.id ?? 0)
    }
    .listStyle(.sidebar)
    // onAppear alone isn't enough: the observation often delivers rows after the
    // view appears, so the first render has nothing to select.
    .onAppear { selectNewestIfNeeded() }
    .onChange(of: history.items) { selectNewestIfNeeded() }
  }

  private func selectNewestIfNeeded() {
    guard selection == nil || !history.items.contains(where: { $0.id == selection }) else { return }
    selection = history.items.first?.id
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Image(systemName: "clipboard")
        .font(.system(size: 26))
        .foregroundStyle(.tertiary)
      Text("Nothing copied yet")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ItemRow: View {
  let item: Item

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: AppIcon.forBundleID(item.sourceBundleID))
        .resizable()
        .frame(width: 16, height: 16)

      Text(item.preview)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 8)

      Text(Self.age(of: item.copiedAtDate))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
    .padding(.vertical, 2)
  }

  /// A `FormatStyle` rather than a shared `RelativeDateTimeFormatter`: value
  /// semantics, so there is no mutable formatter instance being reused across
  /// row renders.
  ///
  /// The clamp matters — anything under a second formats as the nonsensical
  /// "in 0s", which is what showed up on freshly copied rows.
  static func age(of date: Date) -> String {
    let elapsed = Date.now.timeIntervalSince(date)
    guard elapsed >= 1 else { return "now" }
    return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
  }
}

/// Resolving a bundle ID to an icon hits the filesystem, so results are cached —
/// otherwise every scroll frame re-reads every app bundle.
enum AppIcon {
  private static var cache: [String: NSImage] = [:]
  private static let fallback = NSWorkspace.shared.icon(for: .item)

  static func forBundleID(_ bundleID: String?) -> NSImage {
    guard let bundleID else { return fallback }
    if let cached = cache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return fallback
    }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    cache[bundleID] = icon
    return icon
  }
}
