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
  /// Screen position of the pointer the last time hovering was allowed to move
  /// the selection. See `hovered(_:)` — this is what stops a scrolling list from
  /// stealing the selection out from under the arrow keys.
  @State private var mouseAnchor = NSEvent.mouseLocation
  /// Shown when an action the user took did not do what pressing the key implies.
  /// Pinning and deleting are both visible in the list on their own, so success
  /// says nothing here — it is only the cases that silently do nothing that are
  /// indistinguishable from a broken shortcut: a tenth pin with no free slot
  /// (DECISIONS D-14), and a pin or delete whose write failed.
  @State private var notice: String?
  /// Bumped every time a notice is raised, and used as the dismissal task's id.
  /// Keying that task off the message text instead would not restart it on a
  /// second refusal — the string is identical, so SwiftUI sees no change and the
  /// notice expires ten seconds after the *first* one rather than the latest.
  @State private var noticeToken = 0
  /// The vault is a mode of this panel, not a window of its own — using an entry
  /// means typing it into the app you were in, and that plumbing only exists here.
  @State private var mode = PanelMode.history
  /// A history row on its way into the vault. Non-nil raises the editor sheet.
  @State private var vaultDraft: VaultDraft?

  var body: some View {
    Group {
      if mode == .vault {
        VaultView(onClose: onClose, onExit: { mode = .history })
      } else {
        historyBody
      }
    }
    // Reopening always lands on the history. Attached out here rather than inside
    // either branch, because the branch that is not on screen is not listening.
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowPanelDidOpen)) { _ in
      mode = .history
    }
    // Raised from the context menu below. Held open the same way the vault's own
    // editor is — the panel must not disappear out from under a half-typed secret.
    .panelSheet(item: $vaultDraft) { draft in
      VaultEditor(draft: draft) { name, value in
        switch VaultStore.commit(draft, name: name, value: value) {
        case .failed(let message):
          return message
        case .saved(let warning):
          if let warning { raise(warning) }
          return nil
        }
      }
    }
  }

  private var historyBody: some View {
    VStack(spacing: 0) {
      searchField
      if let notice {
        Text(notice)
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
    // The panel floats over whatever app you were typing in, which is the one
    // place glass is the right material rather than a costume. The window itself
    // is transparent (`Panel.init`) so there is something behind this to refract;
    // the corner radius has to match the window's or the fill shows through at
    // the corners.
    .liquidGlass(in: .rect(cornerRadius: 12))
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
    .task(id: noticeToken) {
      guard notice != nil else { return }
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled else { return }
      notice = nil
    }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    // `keys:` rather than the single-key overload, because that one hands back no
    // modifiers and Shift+Return has to be distinguishable from a bare one.
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
    .onKeyPress(phases: .down) { press in
      guard Self.isDelete(press), press.modifiers.contains(.option), let selection
      else { return .ignored }
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
    // Option for the same reason Option+P needs it: focus lives in the search
    // field, so a bare V has to keep typing. Bound here and on the field below.
    .onKeyPress(keys: ["v"]) { press in
      guard press.modifiers.contains(.option) else { return .ignored }
      mode = .vault
      return .handled
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowOpenURL)) { _ in
      openSelectedURL()
    }
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowPanelDidOpen)) { _ in
      now = .now
      // Opens with nothing selected. Hovering selects now, so re-anchoring here is
      // what keeps that true: the rows appear underneath wherever the pointer
      // already was, and without this that counts as a hover and lights a row the
      // user never pointed at. Moving the mouse a single pixel selects as normal.
      mouseAnchor = NSEvent.mouseLocation
      selection = nil
      query = ""
      notice = nil
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
        // Return. The field eats a modified one and reports nothing, so the
        // modified chord did nothing at all until this handler existed —
        // measured, not guessed, back when it was Option+Enter. It now carries
        // Shift+Enter, and the trap is the same. onKeyPress on the focused field
        // sees the event before the field's own handling, which is the only
        // place a modified Return is still interceptable.
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
        // Same trap as the two above: the focused field swallows the event before
        // the panel-level handler sees it.
        .onKeyPress(keys: ["v"], phases: .down) { press in
          guard press.modifiers.contains(.option) else { return .ignored }
          mode = .vault
          return .handled
        }
        // Same trap as the two above, and the reason Option+Delete never worked at
        // all: bound only on the panel, which the focused field never lets the
        // event reach. Return and Option+P were each fixed this way after being
        // found dead; Delete was simply missed.
        //
        // No `?? history.items.first?.id` fallback here, unlike Return and P. With
        // nothing selected those two act on the top row because acting on the top
        // result is what the user meant — pasting it, pinning it. Deleting it is
        // not: a key that silently destroys whatever happens to be first is worse
        // than one that does nothing. An explicit selection is required.
        .onKeyPress(phases: .down) { press in
          guard Self.isDelete(press), press.modifiers.contains(.option), let selection
          else { return .ignored }
          delete(selection)
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


  /// Hovering selects, the way it does in a menu — there is one highlight, and it
  /// is wherever the pointer is.
  ///
  /// The guard is the whole reason this is not just `selection = id` on the row.
  /// `onHover` cannot tell "the pointer moved onto this row" from "this row
  /// scrolled under a pointer that has not moved", and the second one happens on
  /// every arrow key: the list scrolls, a new row slides under the stationary
  /// cursor, and the selection snaps back to it. Comparing the pointer's screen
  /// position against where it was when hovering last won separates the two.
  ///
  /// Nothing clears the selection on hover-*out*, also matching a menu: leaving a
  /// row leaves it lit, so the panel never ends up with nothing selected because
  /// the pointer happened to drift into the search field.
  private func hovered(_ itemID: Int64) {
    let pointer = NSEvent.mouseLocation
    guard pointer != mouseAnchor else { return }
    mouseAnchor = pointer
    selection = itemID
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
    // Re-anchor before moving. The move can scroll the list, which drags a
    // different row under a pointer that never moved — `hovered(_:)` compares
    // against this to tell that apart from a real mouse move.
    mouseAnchor = NSEvent.mouseLocation

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
    // The row staying put is the only other signal a failed delete gives, and the
    // list is a live observation — so it simply does not move, which reads as the
    // key not working. Worse than that, deleting an item is how you get rid of
    // something you did not want kept, and believing that worked when it did not
    // is the failure that actually costs the user something.
    guard ItemRepository.delete(id: itemID) else {
      raise("Couldn't delete that item — the change wasn't saved.")
      return
    }
    notice = nil
  }

  /// FR-5.2's Option+P. The list is a live observation, so pinning redraws
  /// itself — the only outcome that needs saying out loud is the refusal.
  /// A `switch` rather than the old `guard case .slotsFull`, because a failed
  /// write used to be reported as `.slotsFull` — telling the user all nine slots
  /// were taken when the change simply had not been saved. Now that the two are
  /// distinguishable they have to be said differently, and falling through to
  /// silence on `.failed` would leave the same "broken shortcut" impression the
  /// notice exists to prevent.
  private func togglePin(_ itemID: Int64) {
    selection = itemID
    switch ItemRepository.togglePin(id: itemID) {
    case .pinned, .unpinned:
      notice = nil
    case .slotsFull:
      raise("All \(ItemRepository.pinSlots.count) pin slots are in use — unpin one first.")
    case .failed:
      raise("Couldn't pin that item — the change wasn't saved.")
    }
  }

  private func raise(_ message: String) {
    notice = message
    noticeToken += 1
  }

  /// Moves a history row into the vault: name it, seal it, insert it, and only
  /// then delete the plaintext row. The ordering lives in `VaultStore.commit` —
  /// this half is the prompt.
  ///
  /// The unlock comes before the sheet rather than after it. Sealing needs the
  /// value key, so asking afterwards would mean typing a name and then being told
  /// the thing could not be saved.
  private func moveToVault(_ item: ItemSummary) {
    selection = item.id
    Task {
      // `ItemSummary` deliberately carries no content — that is what the type is
      // for — so the full text is fetched here, once, and never logged.
      guard let content = ItemRepository.item(id: item.id)?.content, !content.isEmpty else {
        raise("That item's text is gone — there is nothing to move.")
        return
      }
      guard await VaultStore.unlock(onError: raise) else { return }
      vaultDraft = VaultDraft(
        title: "Move to Vault",
        name: VaultStore.suggestedName(for: item),
        value: content,
        moveFromItemID: item.id
      )
    }
  }

  /// FR-5.2's action table for Return, inverted by DECISIONS D-22: every Return
  /// pastes, and Shift decides plain text. You opened the panel to *use* an item,
  /// so the common case is the one that should carry no modifier.
  ///
  /// There is deliberately no copy-without-paste chord. The cases where pasting
  /// cannot happen — no Accessibility grant, secure input held — already fall back
  /// to copy on their own, because `Clipboard.copy` writes the pasteboard before
  /// `Paster.paste` checks either. What is left is "put it on the clipboard for
  /// somewhere else", which is rare enough to live in the context menu.
  private func perform(_ itemID: Int64, modifiers: EventModifiers) {
    paste(itemID, plainText: modifiers.contains(.shift))
  }

  private func paste(_ itemID: Int64, plainText: Bool) {
    selection = itemID
    let copied = Clipboard.copy(itemID: itemID, plainText: plainText)
    // Closed immediately, without copy()'s confirmation beat: the text arriving
    // in the other app is the confirmation, and PRD HP-2's timing problem only
    // starts once the panel is gone.
    onClose()
    // Nothing was written, so the pasteboard still holds whatever the user copied
    // last. Pressing Return and getting nothing is confusing; pressing Return and
    // having the *previous* clipboard item land in the document is worse, and this
    // app's clipboard history is exactly the place a password can be sitting.
    // `Clipboard.copy` has already logged why. No alert: the panel is on its way
    // out, the failure is rare, and a modal over the app the user was typing in
    // costs more than the silence does.
    guard copied else { return }
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

  /// Matched by character rather than through `onKeyPress(keys:)`, because that
  /// filter does not fire for Delete — measured, not guessed. A probe on the same
  /// event reported `key=KeyEquivalent(character: "\u{7F}")` with `.option` set
  /// and a row selected, while a handler registered as
  /// `keys: [.delete, .deleteForward]` was never called at all.
  ///
  /// This is the whole of the "Option+Delete does nothing" bug. Both bindings were
  /// written the same way, so neither has ever fired, and the focus story that
  /// explains Return and Option+P — the field swallowing events before the panel
  /// sees them — was never the cause here.
  ///
  /// U+007F is Delete (Backspace); U+F728 is `NSDeleteFunctionKey`, forward delete.
  private static func isDelete(_ press: KeyPress) -> Bool {
    guard let scalar = press.characters.unicodeScalars.first else { return false }
    return scalar.value == 0x7F || scalar.value == 0xF728
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
    // Deliberately no `selection:` binding, and the style is `.plain` rather than
    // `.sidebar`. Both draw a highlight of their own that cannot be turned off —
    // `.listRowBackground(.clear)` does not reach it — so the row's accent fill
    // landed *inside* the sidebar style's wider tinted capsule and every selected
    // row wore a pale blue halo. Nothing here needs List's selection anyway: the
    // arrow keys have been handled by `move(_:)` since the List stopped holding
    // focus, and the rows paint themselves. Dropping the binding is what leaves a
    // single clean fill.
    //
    // The cost is that scrolling to an offscreen selection is now ours too, hence
    // the reader below.
    ScrollViewReader { proxy in
      List {
        // No `Section`. The headers are ordinary rows, because a real section
        // header drags the list's own separator along with it and there is no way
        // to turn that off on macOS — `.listSectionSeparator(.hidden)` is an iOS
        // modifier that silently does nothing here, which is how "Pinned" ended up
        // with two rules under it, the list's and ours. Without sections there is
        // one line and it is the one we drew.
        //
        // The labels are worth keeping either way: a pin only announces itself
        // through the ⌃⌘N badge, and with nothing below to compare against there
        // was no boundary to read.
        if pinnedCount > 0 {
          sectionHeader("Pinned")
          ForEach(history.items.prefix(pinnedCount), content: row)
          sectionHeader("Recent")
          ForEach(history.items.dropFirst(pinnedCount), content: row)
        } else {
          ForEach(history.items, content: row)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      // Rows carry their own height; without this the plain style pads every one
      // to the system minimum and a list of one-line text rows reads twice as
      // tall as the menus it is imitating.
      .environment(\.defaultMinListRowHeight, 0)
      // List used to do this as part of moving the selection. Arrowing past the
      // bottom edge otherwise moves a selection you cannot see.
      .onChange(of: selection) { _, moved in
        guard let moved else { return }
        proxy.scrollTo(moved, anchor: nil)
      }
    }
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

  /// The rule under the title is drawn here rather than left to the list.
  /// `.plain` puts a section separator under the *first* header and not the
  /// second, so "Pinned" had a line and "Recent" did not — and the knob that
  /// controls it is not `.listRowSeparator`, which the rows need hidden for their
  /// own reasons. Drawing both the same way is the only version that stays
  /// symmetrical.
  private func sectionHeader(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Divider()
    }
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .padding(.bottom, 2)
    // Zeroed so the padding above is the only thing positioning this. Left to the
    // list, the title got indented and the rule did not, so the line started to
    // the left of the word it belonged to. Both sit at 8pt now, which is where the
    // selection capsule's edge is.
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private func row(_ item: ItemSummary) -> some View {
    ItemRow(item: item, now: now, isSelected: item.id == selection)
      // `.id`, not `.tag` — there is no selection binding for a tag to feed any
      // more; this is what `ScrollViewReader.scrollTo` addresses.
      .id(item.id)
      .onHover { if $0 { hovered(item.id) } }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      // The highlight has to be the row's full width minus a small inset, the way
      // a menu's is. The plain style's default insets are built for a settings
      // list and leave the fill floating in the middle of the row.
      //
      // Zero on every edge, and the vertical pt that used to live here moved into
      // the row's own padding so the height is unchanged. AppKit draws its
      // context-menu ring (`NSMenuHighlightView`) around the whole row rect and
      // cannot be told not to — see the research note. An inset here is the gap
      // between our fill and that ring, which is what makes it read as a second
      // box rather than an edge on the first one.
      .listRowInsets(EdgeInsets())
      // Passing no `selection:` binding was supposed to be enough to stop `List`
      // drawing a highlight of its own. It is not: the backing `NSTableView` keeps
      // its own selection state and paints it **over** our content when a row is
      // clicked, in the same system blue our fill uses. Two blue rectangles of
      // different sizes, one of them ours, which reads as the row growing on click
      // rather than as a second highlight.
      //
      // Found by stroking our fill red and watching the click paint over the
      // stroke — an overlay on our own background cannot be covered by anything we
      // draw, so whatever covered it was AppKit's.
      .selectionDisabled()
      // Single click, not double: picking a clipboard entry is the whole point
      // of the panel being open, so there is nothing else a click would mean.
      // contentShape makes the blank space in the row clickable too.
      .contentShape(.rect)
      // Pastes rather than copies, matching plain Return (DECISIONS D-22). Copy
      // without pasting stays reachable from the context menu, which is where a
      // mouse user would look for it anyway.
      .onTapGesture { paste(item.id, plainText: false) }
      // Discoverable counterpart to Option+Delete, and the only route for
      // anyone using the mouse.
      .contextMenu {
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
        // Text only. An image would need a parallel encrypted path through
        // `ImageStore`, which the vault design puts out of scope — and an entry
        // that silently moved nothing would be worse than no menu item.
        if item.kind == .text {
          Button("Move to Vault") { moveToVault(item) }
        }
        Divider()
        Button("Delete", role: .destructive) { delete(item.id) }
      }
  }

  private var empty: some View {
    // An empty history and a search that found nothing are different problems,
    // and telling someone who has copied all day that they have nothing reads as
    // the app having lost their data.
    VStack(spacing: 6) {
      Image(systemName: query.isEmpty ? "clipboard" : "magnifyingglass")
        .font(.system(size: 26))
        .foregroundStyle(.tertiary)

      if query.isEmpty {
        Text("Nothing copied yet")
          .foregroundStyle(.secondary)
        // The first thing a new install shows. Saying only "nothing yet" leaves
        // someone who just granted permissions with no idea whether it is
        // working or broken.
        Text("Copy something and it will appear here")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Text("No matches for “\(query)”")
          .foregroundStyle(.secondary)
        // Naming the term matters when the query is a typo or a stale
        // half-word left over from the last open.
        Text("Searches text you copied and text inside screenshots")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ItemRow: View {
  let item: ItemSummary
  let now: Date
  let isSelected: Bool

  /// Where the selection fill sits relative to the row, and how round it is.
  ///
  /// All three are knobs rather than constants because they exist to line our
  /// fill up with something we cannot measure: AppKit draws its context-menu ring
  /// (`NSMenuHighlightView`) around the whole row rect, including the width
  /// `List` reserves for its scroller, and offers no way to ask where that is or
  /// to turn it off. Every value here was read off a screenshot.
  ///
  ///     defaults write com.jayyy044.clipflow rowFillTrailingOverhang -float 12
  ///     defaults write com.jayyy044.clipflow rowFillLeadingOverhang  -float 6
  ///     defaults write com.jayyy044.clipflow rowFillVerticalOverhang -float 1
  ///     defaults write com.jayyy044.clipflow rowFillCornerRadius     -float 4
  ///
  /// Then quit and reopen. Both overhangs are positive numbers that push the fill
  /// *out* past the row's edge, towards where the ring is drawn. Too large and
  /// the fill spills past the ring; too small and the ring reappears outside it.
  ///
  /// ponytail: measured constants, not a `GeometryReader` on every row.
  /// Zero is a legal value — it means square corners, or no overhang — so
  /// presence of the key decides, not whether it is positive. Reading it as
  /// `override > 0 ? override : fallback` made 0 fall through to the fallback,
  /// which is what pushes someone into writing a negative radius to force square
  /// corners. A negative radius does not square the shape: SwiftUI does not
  /// reject it, and the path bulges outward past its own frame.
  private static func knob(_ key: String, _ fallback: CGFloat) -> CGFloat {
    guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
    return max(0, UserDefaults.standard.double(forKey: key))
  }

  /// Three styles rather than one. The timestamp, size hint and OCR snippet each
  /// name `.secondary`/`.tertiary` themselves, and grey on accent blue is
  /// unreadable — the three-argument `foregroundStyle` retargets the whole
  /// hierarchy for the subtree, which is the only way to reach text that has
  /// already chosen its own level.
  private var textStyles: (AnyShapeStyle, AnyShapeStyle, AnyShapeStyle) {
    isSelected
      ? (AnyShapeStyle(.white), AnyShapeStyle(.white.opacity(0.75)), AnyShapeStyle(.white.opacity(0.55)))
      : (AnyShapeStyle(.primary), AnyShapeStyle(.secondary), AnyShapeStyle(.tertiary))
  }

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
    // 6, not 5: the extra pt is the `listRowInsets` this row used to carry, moved
    // inside the fill so the fill reaches the row's edge without the row changing
    // height.
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    // The fill has to span the row, not shrink to the content, or the highlight
    // stops short of the timestamp on rows with a narrow thumbnail.
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(textStyles.0, textStyles.1, textStyles.2)
    .background {
      // One highlight, not two. There used to be a separate weak grey hover fill,
      // which meant arrowing to one row while the cursor sat over another lit both
      // at once and neither one told you what Return would act on. Hovering now
      // *is* selecting (`HistoryView.hovered`), the way a menu behaves, so there
      // is only ever one thing lit.
      //
      // Accent rather than a hardcoded blue: it follows System Settings ›
      // Appearance, so a non-default accent doesn't leave one stray blue row.
      // `selectedContentBackgroundColor`, not `Color.accentColor`: the latter is
      // the *control* accent, and AppKit's table selection — which is what the
      // context-menu ring is drawn to match — uses this one. They are different
      // shades of blue, which is why our fill and the ring never quite agreed.
      RoundedRectangle(cornerRadius: Self.knob("rowFillCornerRadius", 0)) //border radius 
        .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        .padding(.trailing, -Self.knob("rowFillTrailingOverhang", 15)) // right
        .padding(.leading, -Self.knob("rowFillLeadingOverhang", 15)) // left 
        .padding(.vertical, -Self.knob("rowFillVerticalOverhang", 0)) // up and down both at once
        // Diagnostic, off unless asked for:
        //   defaults write com.jayyy044.clipflow rowFillDebugOutline -bool YES
        // Strokes every row's fill, selected or not, so the shape's real bounds
        // are visible against the row's. Answers "is the fill bigger than the row,
        // or are the rows simply taller than their content" by looking rather than
        // by reasoning about SwiftUI's layout.
        .overlay {
          if UserDefaults.standard.bool(forKey: "rowFillDebugOutline") {
            RoundedRectangle(cornerRadius: Self.knob("rowFillCornerRadius", 0))
              .stroke(Color.red, lineWidth: 1)
              .padding(.trailing, -Self.knob("rowFillTrailingOverhang", 15))
              .padding(.leading, -Self.knob("rowFillLeadingOverhang", 15))
              .padding(.vertical, -Self.knob("rowFillVerticalOverhang", 0))
          }
        }
    }
    .contentShape(.rect)
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
