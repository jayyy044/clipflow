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
  /// Whether `items` currently holds search results. Drives FR-6.3's section
  /// split, and is flipped alongside the results rather than read off the query
  /// text — the search is debounced 40 ms, so the two disagree for long enough
  /// to draw a "Pinned" header over a list of matches (DECISIONS D-4).
  private(set) var isSearching = false
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
    let fts = SearchService.ftsQuery(from: query)
    let request = fts.map { SearchService.matching($0) } ?? ItemSummary.recent()
    let searching = fts != nil

    let observation = ValueObservation.tracking { db in try request.fetchAll(db) }
    let started = ContinuousClock.now
    var firstDelivery = true
    task = Task { @MainActor [weak self] in
      do {
        for try await items in observation.values(in: Database.shared) {
          self?.items = items
          self?.isSearching = searching
          // NFR's search latency, measured to the point the rows are in hand
          // rather than to the end of the query: the decode into ItemSummary is
          // part of what the user waits for. Only the first delivery — later
          // ones are the table changing under an open panel, not a search.
          if firstDelivery {
            firstDelivery = false
            Timing.since(started, searching ? "search (\(items.count) rows)" : "list load (\(items.count) rows)")
          }
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
  /// Shown when a pin is refused. Only `slotsFull` sets it: pinning and
  /// unpinning are both visible in the list on their own, but a tenth pin that
  /// silently does nothing is indistinguishable from a broken shortcut
  /// (DECISIONS D-14).
  @State private var pinNotice: String?
  /// Bumped every time a notice is raised, and used as the dismissal task's id.
  /// Keying that task off the message text instead would not restart it on a
  /// second refusal — the string is identical, so SwiftUI sees no change and the
  /// notice expires ten seconds after the *first* one rather than the latest.
  @State private var pinNoticeToken = 0

  var body: some View {
    VStack(spacing: 0) {
      searchField
      if let pinNotice {
        Text(pinNotice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
      }
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
    // A refusal that never leaves stops reading as feedback about the key you
    // just pressed and starts reading as a stuck error about the app. Same shape
    // as the debounce above: a replacement notice cancels this sleep and starts a
    // fresh ten seconds rather than stacking timers, and it dies with the view.
    .task(id: pinNoticeToken) {
      guard pinNotice != nil else { return }
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled else { return }
      pinNotice = nil
    }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    // `keys:` rather than the single-key overload, because that one hands back no
    // modifiers and FR-5.2 puts three different actions on Return.
    .onKeyPress(keys: [.return]) { press in
      guard let selection else { return .ignored }
      perform(selection, modifiers: press.modifiers)
      return .handled
    }
    // With nothing preselected, the arrow keys have no starting point, so the
    // first press has to create one. Once a row is selected the List handles
    // subsequent presses itself, hence .ignored.
    .onKeyPress(.downArrow) { move(1) }
    .onKeyPress(.upArrow) { move(-1) }
    // FR-5.2's Cmd+O. Also bound on the search field below, for the same reason
    // Return is: the field owns focus and may consume the event before the panel
    // ever sees it.
    // Option is required: focus lives in the search field, so plain Delete has to
    // keep editing the query (FR-5.2).
    .onKeyPress(keys: [.delete, .deleteForward]) { press in
      guard press.modifiers.contains(.option), let selection else { return .ignored }
      delete(selection)
      return .handled
    }
    // FR-5.2's Option+P. Option for the same reason Option+Delete needs it and
    // Return does not: focus lives in the search field, so a bare P has to keep
    // typing. Bound here *and* on the field below — whichever holds focus sees
    // it first and returns .handled, so it never fires twice.
    .onKeyPress(keys: ["p"]) { press in
      guard press.modifiers.contains(.option), let selection else { return .ignored }
      togglePin(selection)
      return .handled
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowOpenURL)) { _ in
      openSelectedURL()
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowPanelDidOpen)) { _ in
      now = .now
      // Opens with nothing selected: blue means "this is what you just picked",
      // never "this is where the cursor happens to be". Hover covers the latter.
      selection = nil
      query = ""
      pinNotice = nil
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
        //
        // onSubmit alone is not enough: it fires only for an *unmodified*
        // Return. The field eats Option+Return and reports nothing, so
        // Option+Enter did nothing at all until this handler existed —
        // measured, not guessed. onKeyPress on the focused field sees the event
        // before the field's own handling, which is the only place a modified
        // Return is still interceptable.
        .onKeyPress(keys: [.return], phases: .down) { press in
          guard !press.modifiers.isEmpty else { return .ignored }  // plain Return stays with onSubmit
          guard let target = selection ?? history.items.first?.id else { return .ignored }
          perform(target, modifiers: press.modifiers)
          return .handled
        }
        // The focused field swallows key presses before the panel-level handler
        // sees them, exactly as it does for a modified Return above.
        .onKeyPress(keys: ["p"], phases: .down) { press in
          guard press.modifiers.contains(.option),
                let target = selection ?? history.items.first?.id
          else { return .ignored }
          togglePin(target)
          return .handled
        }
        .onSubmit {
          guard let target = selection ?? history.items.first?.id else { return }
          perform(target, modifiers: Self.modifiers(from: NSEvent.modifierFlags))
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


  /// Moves the selection through the list ourselves rather than letting `List`
  /// do it.
  ///
  /// `List` only handles arrow keys when it holds focus, and focus has to stay
  /// in the search field so typing keeps filtering (FR-6.5). Deferring to the
  /// List meant the first press selected a row and every press after it did
  /// nothing.
  private func move(_ step: Int) -> KeyPress.Result {
    guard !history.items.isEmpty else { return .ignored }

    guard let current = selection,
          let index = history.items.firstIndex(where: { $0.id == current })
    else {
      // Nothing selected yet: Down enters at the top, Up at the bottom.
      selection = step > 0 ? history.items.first?.id : history.items.last?.id
      return .handled
    }

    // Clamped, not wrapped — running off the end of a list of copied items and
    // silently reappearing at the other end loses your place.
    let next = min(max(index + step, 0), history.items.count - 1)
    selection = history.items[next].id
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

  /// FR-5.2's Option+P. The list is a live observation, so pinning redraws
  /// itself — the only outcome that needs saying out loud is the refusal.
  private func togglePin(_ itemID: Int64) {
    selection = itemID
    guard case .slotsFull = ItemRepository.togglePin(id: itemID) else {
      pinNotice = nil
      return
    }
    pinNotice = "All \(ItemRepository.pinSlots.count) pin slots are in use — unpin one first."
    pinNoticeToken += 1
  }

  private func copy(_ itemID: Int64) {
    // Highlight first, close second. The clipboard write happens immediately —
    // only the dismissal waits, long enough for the blue to register as
    // confirmation of what was picked. Short enough not to feel like lag.
    selection = itemID
    Clipboard.copy(itemID: itemID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { onClose() }
  }

  /// FR-5.2's action table for Return. Option decides copy versus paste and
  /// Shift decides plain text, read off the key press for the same reason
  /// Option+Delete is bound that way: focus lives in the search field, so an
  /// unmodified Return has to stay available for the fast path.
  private func perform(_ itemID: Int64, modifiers: EventModifiers) {
    guard modifiers.contains(.option) else {
      copy(itemID)
      return
    }
    paste(itemID, plainText: modifiers.contains(.shift))
  }

  private func paste(_ itemID: Int64, plainText: Bool) {
    selection = itemID
    Clipboard.copy(itemID: itemID, plainText: plainText)
    // Closed immediately, without copy()'s confirmation beat: the text arriving
    // in the other app is the confirmation, and PRD HP-2's timing problem only
    // starts once the panel is gone.
    onClose()
    Paster.paste()
  }

  /// Driven by the panel's `performKeyEquivalent`, since a Command chord never
  /// reaches SwiftUI's key handling. Falls back to the top row for the same
  /// reason Return does: with nothing selected, the first result is what the user
  /// means.
  private func openSelectedURL() {
    guard let target = selection ?? history.items.first?.id else { return }
    openURL(target)
  }

  /// FR-5.3: first URL, system default browser. The browser picker was cut
  /// (DECISIONS D-5.5), so there is nothing to configure and nothing to resolve —
  /// `open(_:)` is the whole action. Reports whether there was a link, so the key
  /// press can fall through on rows that have none.
  @discardableResult
  private func openURL(_ itemID: Int64) -> Bool {
    guard let url = history.items.first(where: { $0.id == itemID })?.firstURL else { return false }
    selection = itemID
    NSWorkspace.shared.open(url)
    // Closed like paste rather than like copy: the browser coming forward is the
    // confirmation, and there is no highlight worth holding the panel open for.
    onClose()
    return true
  }

  private static func modifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
    var modifiers = EventModifiers()
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
  }

  /// FR-6.3: pinned section, then the flat history. Only while idle — a search
  /// is one ranked list with pinned boosted instead, or a pinned match would be
  /// drawn in both halves (DECISIONS D-4). `recent()` already emits the pinned
  /// rows first, so this splits a prefix rather than re-sorting.
  private var pinnedCount: Int {
    history.isSearching ? 0 : history.items.prefix(while: \.pinned).count
  }

  private var list: some View {
    // `selection` plus a focused List is what makes the arrow keys work; there
    // is no manual key handling here.
    List(selection: $selection) {
      if pinnedCount > 0 {
        Section("Pinned") {
          ForEach(history.items.prefix(pinnedCount), content: row)
        }
        Section {
          ForEach(history.items.dropFirst(pinnedCount), content: row)
        }
      } else {
        ForEach(history.items, content: row)
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

  @ViewBuilder
  private func row(_ item: ItemSummary) -> some View {
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
        Button("Paste") { paste(item.id, plainText: false) }
        Button("Paste as Plain Text") { paste(item.id, plainText: true) }
        // Absent, not disabled, on rows without a link: the glyph already says
        // which rows have one, and a permanently greyed entry on most rows is
        // noise. Same reasoning as the status menu's "Enable Pasting…".
        if item.hasURL {
          Button("Open URL") { openURL(item.id) }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { togglePin(item.id) }
        Divider()
        Button("Delete", role: .destructive) { delete(item.id) }
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

      // DECISIONS S-16: why this row matched. Four thumbnails of the same
      // terminal are indistinguishable without it.
      if let snippet = item.ocrSnippet, !snippet.isEmpty, item.kind == .image {
        Text(snippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 8)

      // The slot, not a pin glyph: the section header already says these rows
      // are pinned, and the number is the part you cannot work out by looking —
      // it is what Option+N pastes, and it does not follow list position
      // (DECISIONS D-3).
      if let slot = item.pinSlot {
        Text("⌃⌘\(slot)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .help("⌃⌘\(slot) pastes this without opening ClipFlow")
          .fixedSize()
      }

      // FR-6.4: the row holds a link, so Cmd+O does something here and nowhere
      // else. Needed on the row because the URL is often past the preview
      // cut-off, or on a later line the preview never shows.
      if item.hasURL {
        Image(systemName: "link")
          .foregroundStyle(.tertiary)
          .help("⌘O opens this link")
      }

      // FR-6.4: this screenshot's text is not in the index yet. Without the
      // marker, searching for a word that is plainly visible in the thumbnail
      // and getting nothing reads as the feature being broken.
      if item.isOCRPending {
        Image(systemName: "text.viewfinder")
          .foregroundStyle(.tertiary)
          .help("Reading text…")
      }

      // Two long items sharing an opening paragraph render as the same preview,
      // and the size is the only thing on the row that separates them.
      if let sizeHint = item.sizeHint {
        Text(sizeHint)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize()
      }

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
