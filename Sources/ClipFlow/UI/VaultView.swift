import AppKit
import CryptoKit
import SwiftUI

/// Which face the panel is showing. The vault is a *mode* of the existing panel
/// rather than a window of its own, because using an entry means typing it into
/// the app you were in and `Paster`'s target-app plumbing only exists here.
enum PanelMode {
  case history
  case vault
}

/// One vault entry as the list needs it: the name already opened, the value still
/// sealed.
///
/// `name` is optional on purpose. A row whose sealed name fails its GCM tag is
/// corrupt, and drawing it as an empty string would present it as a junk entry the
/// user then deletes — which is the one irreversible thing to do with a secret
/// that is merely unreadable by this build.
struct VaultRow: Identifiable, Hashable {
  let id: Int64
  let name: String?
  let sealedValue: Data
  let createdAt: Int64
}

/// A pending add, edit or move. Carried as a value so the same sheet serves all
/// three, and so `HistoryView` can raise it without knowing anything about how an
/// entry is sealed.
struct VaultDraft: Identifiable {
  let id = UUID()
  var title: String
  var name: String
  var value: String
  /// Set when an existing entry is being edited; nil inserts a new row.
  var entryID: Int64?
  var createdAt: Int64?
  /// Set by "Move to Vault". The history row is deleted **after** the vault write
  /// is confirmed — see `VaultStore.commit`.
  var moveFromItemID: Int64?
}

/// Everything the two views need to do to the vault, in one place: names are
/// sealed under a different key from values, and neither view should have to know
/// that.
///
/// Nothing here logs a name or a value, and nothing here writes the pasteboard.
@MainActor
enum VaultStore {
  enum Outcome {
    /// Written. The message, when present, is something that went wrong
    /// *afterwards* and does not undo the save.
    case saved(String?)
    case failed(String)
  }

  /// Nil means the read failed, following `VaultRepository.all()`'s rule — an
  /// unreadable vault must never be drawn as an empty one.
  static func rows() -> [VaultRow]? {
    guard let entries = VaultRepository.all(), let key = try? VaultKeys.nameKey() else { return nil }
    return entries.compactMap { entry -> VaultRow? in
      // A row with no id cannot be acted on; GRDB fills it in on insert, so this
      // is unreachable in practice and silently dropping it beats a crash.
      guard let id = entry.id else { return nil }
      return VaultRow(
        id: id,
        name: try? VaultCrypto.open(entry.sealedName, using: key),
        sealedValue: entry.sealedValue,
        createdAt: entry.createdAt
      )
    }
    // ponytail: in-memory sort of decrypted names, fine to ~1000 entries.
    // Corrupt rows sort last rather than being hidden — they still need deleting.
    .sorted { left, right in
      switch (left.name, right.name) {
      case let (leftName?, rightName?):
        return leftName.localizedStandardCompare(rightName) == .orderedAscending
      case (nil, _?): return false
      case (_?, nil): return true
      case (nil, nil): return left.id < right.id
      }
    }
  }

  /// Nil after reporting why, and never a plaintext-shaped placeholder.
  ///
  /// The two failures have to be worded differently. The session idling out
  /// while the panel sat open is ordinary and recoverable — the fix is to unlock
  /// again — whereas "Couldn't read that entry" is what makes people delete a
  /// secret that was merely unreadable this once.
  static func open(_ row: VaultRow, onError: (String) -> Void) -> String? {
    do {
      return try VaultSession.shared.open(row.sealedValue)
    } catch VaultCrypto.Failure.locked {
      onError("The vault locked. Unlock and try again.")
    } catch {
      onError("Couldn't read that entry.")
    }
    return nil
  }

  /// Seals and writes. **Insert first, then delete the history copy** — the
  /// reverse loses the item outright if the seal fails, and the seal can fail for
  /// something as ordinary as the session having idled out while the sheet was up.
  static func commit(_ draft: VaultDraft, name: String, value: String) -> Outcome {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .failed("Give this entry a name.") }
    guard !value.isEmpty else { return .failed("There is nothing to save.") }

    guard let nameKey = try? VaultKeys.nameKey(),
          let sealedName = try? VaultCrypto.seal(name, using: nameKey)
    else { return .failed("Couldn't reach the vault's keys.") }

    guard let sealedValue = try? VaultSession.shared.seal(value) else {
      return .failed("The vault locked before this was saved. Unlock and try again.")
    }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    var entry = VaultEntry(
      id: draft.entryID,
      sealedName: sealedName,
      sealedValue: sealedValue,
      createdAt: draft.createdAt ?? now,
      updatedAt: now
    )
    guard VaultRepository.save(&entry) else {
      return .failed("Couldn't save that to the vault — the change wasn't written.")
    }

    guard let itemID = draft.moveFromItemID else { return .saved(nil) }
    // Only now. `ItemRepository.delete` fires `items_fts_ad`, which is what purges
    // the plaintext out of the search index; failing it leaves a duplicate, which
    // is recoverable, where the other order leaves nothing, which is not.
    guard ItemRepository.delete(id: itemID) else {
      return .saved("Saved to the vault, but the copy in your history is still there.")
    }
    return .saved(nil)
  }

  /// Unlocks, and keeps the panel on screen for as long as the prompt is up.
  ///
  /// The hold is the same one the sheet uses and it is here for the same reason:
  /// the authentication sheet takes key focus away from the panel, and a panel
  /// that closes on focus loss would take itself — and the vault — down the
  /// instant Touch ID appeared.
  ///
  /// Already unlocked returns true without prompting; `VaultSession.unlock()` is
  /// idempotent, so every value action can front itself with this and the user
  /// still sees exactly one prompt per visit.
  ///
  /// `onError` is not called for a cancelled prompt — the user changed their mind
  /// and does not need to be told what they just did.
  static func unlock(onError: (String) -> Void) async -> Bool {
    guard !VaultSession.shared.isUnlocked else { return true }
    PanelHold.acquire()
    defer { PanelHold.release() }
    do {
      try await VaultSession.shared.unlock()
      return true
    } catch VaultKeys.Failure.userCancelled {
      return false
    } catch VaultKeys.Failure.unavailable {
      onError("macOS wouldn't unlock the vault — Touch ID or a login password has to be set up.")
      return false
    } catch {
      onError("Couldn't unlock the vault.")
      return false
    }
  }

  /// A starting name built from the row's metadata — never from its content.
  ///
  /// Names are sealed under `nameKey()`, which has no user-presence requirement
  /// so the locked vault can still draw a readable list. Anything derived from
  /// the item's text therefore ends up in the one column Touch ID does not
  /// protect, and a pre-filled field shows no placeholder to warn about it. The
  /// item this feature exists for is a copied SSN, whose preview *is* the SSN.
  ///
  /// No truncating, no sanitising, no "only when it looks safe": the source app
  /// and the date are all this may ever see.
  static func suggestedName(for item: ItemSummary) -> String {
    let date = Date(timeIntervalSince1970: Double(item.copiedAt) / 1000)
      .formatted(.dateTime.day().month(.abbreviated))
    guard let app = item.sourceAppName, !app.isEmpty else { return "Clipboard, \(date)" }
    return "From \(app), \(date)"
  }
}

/// Browse and use. Add and edit live in a sheet (`VaultEditor`), because this
/// panel closes on focus loss and a half-typed SSN must not be able to vanish.
struct VaultView: View {
  /// Closes the whole panel. `Panel.close()` locks the vault on the way out, so
  /// anything needing plaintext must have it in hand before calling this.
  var onClose: () -> Void
  /// Back to the history list, panel stays open.
  var onExit: () -> Void

  @ObservedObject private var session = VaultSession.shared
  /// Nil means the read failed. Distinct from `[]`, which is an empty vault.
  @State private var rows: [VaultRow]?
  /// Values the user asked to see, cleared whenever the session locks.
  @State private var revealed: [Int64: String] = [:]
  @State private var draft: VaultDraft?
  @State private var notice: String?
  @State private var noticeToken = 0

  var body: some View {
    VStack(spacing: 0) {
      header
      if let notice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
      }
      Divider()
      content
    }
    .frame(minWidth: 320, minHeight: 200)
    .liquidGlass(in: .rect(cornerRadius: 12))
    .onAppear(perform: reload)
    // A lock is not a lock if it leaves plaintext on screen. Covers all three
    // triggers at once — screen lock, idle timeout, and the panel closing.
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowVaultLocked)) { _ in
      revealed = [:]
    }
    // Same shape as `HistoryView`'s: a replacement notice restarts the countdown
    // rather than stacking timers.
    .task(id: noticeToken) {
      guard notice != nil else { return }
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled else { return }
      notice = nil
    }
    // Escape steps back to the history rather than closing the panel: this is a
    // mode, and the way out of a mode is the way you came in.
    .onKeyPress(.escape) {
      onExit()
      return .handled
    }
    .panelSheet(item: $draft) { pending in
      VaultEditor(draft: pending) { name, value in
        switch VaultStore.commit(pending, name: name, value: value) {
        case .failed(let message):
          return message
        case .saved(let warning):
          reload()
          if let warning { raise(warning) }
          return nil
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: onExit) {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.plain)
      .help("Back to your clipboard history")

      Image(systemName: session.isUnlocked ? "lock.open" : "lock")
        .foregroundStyle(.secondary)
      Text("Vault").font(.headline)

      Spacer()

      // The single Unlock control. Every value action also unlocks on demand, so
      // this is the discoverable route rather than the only one.
      if session.isUnlocked {
        Button("Lock") { session.lock() }
          .controlSize(.small)
      } else {
        Button("Unlock") {
          Task { _ = await VaultStore.unlock(onError: raise) }
        }
        .controlSize(.small)
      }

      Button {
        Task {
          // Sealing needs the value key, so the prompt comes before the sheet
          // rather than after the user has typed a secret into it.
          guard await VaultStore.unlock(onError: raise) else { return }
          draft = VaultDraft(title: "New Vault Entry", name: "", value: "")
        }
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.plain)
      .help("Add an entry")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private var content: some View {
    if let rows {
      if rows.isEmpty {
        empty
      } else {
        list(rows)
      }
    } else {
      // Never "your vault is empty" — that is a sentence the user acts on.
      VStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 26))
          .foregroundStyle(.tertiary)
        Text("Couldn't read the vault").foregroundStyle(.secondary)
        Text("Nothing has been lost. Quit and reopen ClipFlow, then try again.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Image(systemName: "lock")
        .font(.system(size: 26))
        .foregroundStyle(.tertiary)
      Text("Nothing in the vault yet").foregroundStyle(.secondary)
      Text("Add an entry, or right-click something in your history and move it here.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
      // The one thing the design cannot recover from, said once, where the first
      // entry is about to be added. No dialog: the keys are bound to this Mac's
      // Secure Enclave and an export made beforehand is the only way back.
      Text("Entries are locked to this Mac. If it is erased, repaired or replaced, an export made beforehand is the only way to get them back — Settings › Vault.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Same list construction as `HistoryView`: `.plain`, no `Section`, no
  /// selection binding. All three are load-bearing on macOS — a real section
  /// header drags the list's own separator along and `.listSectionSeparator` does
  /// nothing here, and the built-in selection highlight cannot be turned off by
  /// `.listRowBackground(.clear)`.
  private func list(_ rows: [VaultRow]) -> some View {
    List {
      ForEach(rows, content: row)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 0)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  private func row(_ entry: VaultRow) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.name ?? "Unreadable entry")
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(entry.name == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        Text(revealed[entry.id] ?? "••••••••")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 8)

      if entry.name == nil {
        // A row that cannot be opened has exactly one useful action left, and it
        // is in the context menu with the rest.
        Text("corrupt")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Button("Use") { use(entry) }
          .controlSize(.small)
          .help("Types this into the app you were in. Never touches your clipboard.")
        Button {
          toggleReveal(entry)
        } label: {
          Image(systemName: revealed[entry.id] == nil ? "eye" : "eye.slash")
        }
        .buttonStyle(.plain)
        .help(revealed[entry.id] == nil ? "Show the value" : "Hide the value")
      }
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    .contentShape(.rect)
    .contextMenu {
      if entry.name != nil {
        Button("Use") { use(entry) }
        Button(revealed[entry.id] == nil ? "Reveal" : "Hide") { toggleReveal(entry) }
        Divider()
        Button("Rename or Edit…") { edit(entry) }
        // Deliberately last before the destructive action and deliberately
        // wordy: this is the one route that puts a vault value somewhere every
        // other app on the machine can read it.
        Button("Copy anyway (clipboard clears in 60s)") { copyAnyway(entry) }
        Divider()
      }
      Button("Delete", role: .destructive) { delete(entry) }
    }
  }

  private func reload() {
    rows = VaultStore.rows()
  }

  private func raise(_ message: String) {
    notice = message
    noticeToken += 1
  }

  /// Decrypts *before* closing the panel, because closing locks the vault.
  private func use(_ entry: VaultRow) {
    Task {
      guard await VaultStore.unlock(onError: raise) else { return }
      guard let value = VaultStore.open(entry, onError: raise) else { return }
      onClose()
      Paster.type(value)
    }
  }

  private func toggleReveal(_ entry: VaultRow) {
    guard revealed[entry.id] == nil else {
      revealed[entry.id] = nil
      return
    }
    Task {
      guard await VaultStore.unlock(onError: raise) else { return }
      guard let value = VaultStore.open(entry, onError: raise) else { return }
      revealed[entry.id] = value
    }
  }

  private func edit(_ entry: VaultRow) {
    Task {
      guard await VaultStore.unlock(onError: raise) else { return }
      guard let value = VaultStore.open(entry, onError: raise) else { return }
      guard let name = entry.name else {
        raise("Couldn't read that entry.")
        return
      }
      draft = VaultDraft(
        title: "Edit Vault Entry",
        name: name,
        value: value,
        entryID: entry.id,
        createdAt: entry.createdAt
      )
    }
  }

  private func delete(_ entry: VaultRow) {
    guard VaultRepository.delete(id: entry.id) else {
      raise("Couldn't delete that entry — the change wasn't saved.")
      return
    }
    revealed[entry.id] = nil
    reload()
  }

  /// The explicit escape hatch from V-5. Everything about it is deliberate:
  /// `ConcealedType` so ClipFlow's own monitor and every other clipboard manager
  /// skip it, `ignore(changeCount:)` so our own capture loop does too, and a
  /// 60-second wipe so the window is bounded.
  ///
  /// The wipe is an unstructured `Task` on purpose — it has to outlive this view,
  /// which disappears the moment the panel closes. It does **not** outlive the
  /// process: quitting inside the minute leaves the value on the pasteboard, and
  /// nothing in this app can fix that from the other side of a `SIGTERM`.
  private func copyAnyway(_ entry: VaultRow) {
    Task {
      guard await VaultStore.unlock(onError: raise) else { return }
      guard let value = VaultStore.open(entry, onError: raise) else { return }

      let pasteboard = NSPasteboard.general
      let cleared = pasteboard.clearContents()
      pasteboard.setString(value, forType: .string)
      // Same tag 1Password and Bitwarden set. `PasteboardMonitor.skipTypes`
      // already refuses anything carrying it, so this is belt and braces with
      // the ignore below — and it is what tells *other* clipboard managers to
      // leave it alone, which the ignore cannot.
      pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))
      PasteboardMonitor.shared.ignore(changeCount: cleared)

      let written = pasteboard.changeCount
      raise("Copied. Your clipboard clears in 60 seconds.")

      Task {
        try? await Task.sleep(for: .seconds(60))
        // Someone copied something else in the meantime; clearing now would
        // throw away their work rather than our secret.
        guard NSPasteboard.general.changeCount == written else { return }
        PasteboardMonitor.shared.ignore(changeCount: NSPasteboard.general.clearContents())
      }
    }
  }
}

/// Add, edit and move, in a sheet.
///
/// The sheet is the reason `PanelHold` exists: this panel closes when it loses
/// key focus, the sheet takes key focus, and a window that can vanish mid-keystroke
/// is not somewhere anyone should be typing a bank PIN. `panelSheet` holds the
/// panel open for as long as this is on screen.
struct VaultEditor: View {
  let draft: VaultDraft
  /// Nil dismisses; a message keeps the sheet up and shows it. Sealing can fail
  /// for reasons the user can act on (the session idled out), so a failed save
  /// must not throw away what they typed.
  let onSave: (String, String) -> String?

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var value: String
  @State private var showValue = false
  @State private var error: String?

  init(draft: VaultDraft, onSave: @escaping (String, String) -> String?) {
    self.draft = draft
    self.onSave = onSave
    _name = State(initialValue: draft.name)
    _value = State(initialValue: draft.value)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(draft.title).font(.headline)

      // Not a Form: a grouped form inside a 360pt sheet spends most of its width
      // on inset chrome, and there are two fields.
      VStack(alignment: .leading, spacing: 8) {
        TextField("Name — shown even when the vault is locked", text: $name)
        // Masked by default. The toggle is there because a value you cannot see
        // is a value you cannot check before saving it.
        if showValue {
          TextField("Value", text: $value)
        } else {
          SecureField("Value", text: $value)
        }
        Toggle("Show value", isOn: $showValue)
          .controlSize(.small)
      }
      .textFieldStyle(.roundedBorder)

      // New entries only. An edit is already-stored data and the person has seen
      // this once; repeating it on every save is the nag this feature must not be.
      if draft.entryID == nil {
        Text("This is sealed to this Mac and cannot be read anywhere else. Export the vault from Settings if you want a copy that survives losing it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          error = onSave(name, value)
          if error == nil { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 380)
  }
}
