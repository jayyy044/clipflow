import AppKit
import GRDB
import Observation
import SwiftUI

/// Live view of the items table. GRDB pushes a new array whenever the table
/// changes, so nothing has to poll or manually refresh.
@Observable
final class History {
  static let shared = History()

  var items: [ItemSummary] = []
  private var task: Task<Void, Never>?

  private init() {
    observe(query: "")
  }

  /// Re-points the live observation at either the full list or a search.
  ///
  /// The results stay observed rather than fetched once, so a copy made while
  /// the panel is open still appears if it matches what is typed.
  func observe(query: String) {
    task?.cancel()

    // A query of only punctuation reduces to nothing searchable, which shows the
    // unfiltered list rather than an empty one.
    let request = SearchService.ftsQuery(from: query).map { SearchService.matching($0) }
      ?? ItemSummary.recent()

    let observation = ValueObservation.tracking { db in try request.fetchAll(db) }
    task = Task { @MainActor [weak self] in
      do {
        for try await items in observation.values(in: Database.shared) {
          self?.items = items
        }
      } catch is CancellationError {
        // Superseded by the next keystroke.
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
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  /// Reference point the rows date themselves against, refreshed each time the
  /// panel opens. Explicit state rather than a `Date.now` buried in each row, so
  /// SwiftUI can actually see it change and re-render.
  @State private var now = Date.now

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      if history.items.isEmpty {
        empty
      } else {
        list
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .background(.thinMaterial)
    // FR-3.5: 40ms after the last keystroke, not on every one. `.task(id:)`
    // cancels the pending sleep when the query changes again, which is the
    // debounce — no timer to manage.
    .task(id: query) {
      try? await Task.sleep(for: .milliseconds(40))
      guard !Task.isCancelled else { return }
      history.observe(query: query)
    }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    .onKeyPress(.return) {
      guard let selection else { return .ignored }
      copy(selection)
      return .handled
    }
    // With nothing preselected, the arrow keys have no starting point, so the
    // first press has to create one. Once a row is selected the List handles
    // subsequent presses itself, hence .ignored.
    .onKeyPress(.downArrow) { enterList(from: .first) }
    .onKeyPress(.upArrow) { enterList(from: .last) }
    // Option is required: focus lives in the search field, so plain Delete has to
    // keep editing the query (FR-5.2).
    .onKeyPress(keys: [.delete, .deleteForward]) { press in
      guard press.modifiers.contains(.option), let selection else { return .ignored }
      delete(selection)
      return .handled
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowPanelDidOpen)) { _ in
      now = .now
      // Opens with nothing selected: blue means "this is what you just picked",
      // never "this is where the cursor happens to be". Hover covers the latter.
      selection = nil
      query = ""
    }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        // A focused TextField swallows Return, so the panel-level .onKeyPress
        // never sees it. Falling back to the first row is what makes the fast
        // path work: type a few characters, press Enter, done (G2) — without it
        // you would have to arrow into the list first.
        .onSubmit {
          guard let target = selection ?? history.items.first?.id else { return }
          copy(target)
        }
      if !query.isEmpty {
        Button {
          query = ""
          searchFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    // FR-6.5: focus lands here on open, so the panel is type-to-search with no
    // click. The panel is non-activating, so this has to be re-asserted on every
    // open rather than set once.
    .onAppear { searchFocused = true }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowPanelDidOpen)) { _ in
      searchFocused = true
    }
  }

  private enum ListEnd { case first, last }

  private func enterList(from end: ListEnd) -> KeyPress.Result {
    guard selection == nil else { return .ignored }
    selection = end == .first ? history.items.first?.id : history.items.last?.id
    return .handled
  }

  /// Deleting the selected row leaves the selection dangling, so it moves to the
  /// next row down first — matching what the list will look like afterwards.
  private func delete(_ itemID: Int64) {
    if let index = history.items.firstIndex(where: { $0.id == itemID }) {
      let next = history.items[(index + 1)...].first ?? history.items[..<index].last
      selection = next?.id
    }
    ItemRepository.delete(id: itemID)
  }

  private func copy(_ itemID: Int64) {
    // Highlight first, close second. The clipboard write happens immediately —
    // only the dismissal waits, long enough for the blue to register as
    // confirmation of what was picked. Short enough not to feel like lag.
    selection = itemID
    Clipboard.copy(itemID: itemID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { onClose() }
  }

  private var list: some View {
    // `selection` plus a focused List is what makes the arrow keys work; there
    // is no manual key handling here.
    List(history.items, selection: $selection) { item in
      ItemRow(item: item, now: now)
        .tag(item.id)
        // Single click, not double: picking a clipboard entry is the whole point
        // of the panel being open, so there is nothing else a click would mean.
        // contentShape makes the blank space in the row clickable too.
        .contentShape(.rect)
        .onTapGesture { copy(item.id) }
        // Discoverable counterpart to Option+Delete, and the only route for
        // anyone using the mouse.
        .contextMenu {
          Button("Copy") { copy(item.id) }
          Divider()
          Button("Delete", role: .destructive) { delete(item.id) }
        }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    // Insets the whole scroll view, scroll indicator included, so the bar isn't
    // riding the panel's rounded edge. Padding rather than .contentMargins,
    // which insets the content but leaves the indicator where it was.
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    // Nothing is auto-selected any more, but a selected row can still disappear
    // underneath us — evicted by retention, or merged away by dedupe — and a
    // selection pointing at a gone row would let Enter copy nothing.
    .onChange(of: history.items) {
      if let selection, !history.items.contains(where: { $0.id == selection }) {
        self.selection = nil
      }
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Image(systemName: query.isEmpty ? "clipboard" : "magnifyingglass")
        .font(.system(size: 26))
        .foregroundStyle(.tertiary)
      // An empty history and a search that found nothing are different problems,
      // and saying "Nothing copied yet" to someone who has copied all day reads
      // as the app having lost their data.
      Text(query.isEmpty ? "Nothing copied yet" : "No matches")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ItemRow: View {
  let item: ItemSummary
  let now: Date

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: AppIcon.forBundleID(item.sourceBundleID))
        .resizable()
        .frame(width: 20, height: 20)

      // FR-6.4/FR-6.7: image rows show the thumbnail in place of preview text.
      // The text is still the fallback, which is what a missing or unwritable
      // thumbnail degrades to rather than an empty row.
      if let thumbnail = item.thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fit)
          // alignment: .leading is the fix for thumbnails appearing indented —
          // a frame centres its content by default, so a 36pt-wide image inside a
          // 96pt box sat 30pt from the app icon. maxWidth still has to cap it, or
          // a very wide screenshot would push the timestamp off the row.
          .frame(maxWidth: 140, maxHeight: 26, alignment: .leading)
          .clipShape(.rect(cornerRadius: 3))
      } else {
        Text(item.preview)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 8)

      Text(Self.age(of: item.lastActivityDate, relativeTo: now))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .background {
      // Deliberately much weaker than the selection fill, so hover reads as
      // "the mouse is here" and not as "this is what Enter will copy".
      RoundedRectangle(cornerRadius: 6)
        .fill(.primary.opacity(isHovered ? 0.09 : 0))
    }
    .contentShape(.rect)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
  }

  /// A `FormatStyle` rather than a shared `RelativeDateTimeFormatter`: value
  /// semantics, so there is no mutable formatter instance being reused across
  /// row renders.
  ///
  /// The clamp matters — anything under a second formats as the nonsensical
  /// "in 0s", which is what showed up on freshly copied rows.
  static func age(of date: Date, relativeTo now: Date) -> String {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed >= 1 else { return "now" }
    return date.formatted(
      .relative(presentation: .numeric, unitsStyle: .narrow).locale(.autoupdatingCurrent)
    )
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
