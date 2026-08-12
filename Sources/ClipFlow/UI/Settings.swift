import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Everything the user can change that is too small to earn a database column.
///
/// UserDefaults rather than a `settings` table: these are read on the copy path
/// (`excludedBundleIDs` on every capture) and a SQLite round trip per copy buys
/// nothing when the whole payload is a handful of strings.
enum Preferences {
  private static let excludedKey = "excludedBundleIDs"

  /// FR-7.2. Bundle ids, not app names — a name is localized and changes with a
  /// rename, and the bundle id is what `PasteboardMonitor` already has in hand.
  static var excludedBundleIDs: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: excludedKey) ?? []) }
    set { UserDefaults.standard.set(newValue.sorted(), forKey: excludedKey) }
  }

  /// FR-7.4. Persisted, unlike FR-7.3's one-shot: someone who paused capture did
  /// it for a reason that outlives one run of the app, and quietly resuming on
  /// the next launch is the failure mode that actually costs them something.
  /// Honest only because the dimmed icon says so at a glance — without FR-7.4's
  /// other half this would be a hidden setting.
  static var isPaused: Bool {
    get { UserDefaults.standard.bool(forKey: "capturePaused") }
    set { UserDefaults.standard.set(newValue, forKey: "capturePaused") }
  }

  /// Whether the first-launch registration in `AppDelegate` has already run.
  /// Without it, FR-7.7's toggle is undone by the next launch re-registering.
  static let didRegisterLaunchAtLoginKey = "didRegisterLaunchAtLogin"
}

/// FR-7.7. `SMAppService.Status` is the truth and it is not a boolean: macOS
/// commonly parks a successful `register()` at `.requiresApproval`, so a plain
/// checkbox would read "on" for an app that will not come back after a reboot.
enum LaunchAtLogin {
  static var status: SMAppService.Status { SMAppService.mainApp.status }

  static func set(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      // Not fatal — the app still works, it just won't come back after a reboot.
      NSLog("ClipFlow: launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
    }
  }

  /// Nil when the toggle alone is honest. Only the two states where it would lie
  /// have something to say.
  static func caveat(for status: SMAppService.Status) -> String? {
    switch status {
    case .requiresApproval:
      return "Waiting for approval in System Settings › General › Login Items."
    case .notFound:
      return "Unavailable — ClipFlow is not running from an installed app bundle."
    default:
      return nil
    }
  }
}

/// DECISIONS D-2: there is no SwiftUI `App` here — `main.swift` drives
/// `NSApplication` directly — so a `Settings {}` scene does not exist to be
/// opened, and `SettingsLink` has no scene to point at. The window is built by
/// hand, and the app has to be activated first because an `.accessory` app is
/// never active on its own and an inactive app's window cannot take key events —
/// which the shortcut recorders need in order to record anything.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  static let shared = SettingsWindow()
  private var window: NSWindow?

  func show() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "ClipFlow Settings"
      // The window is created once and reopened; releasing it on close would
      // leave `window` dangling.
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      window.contentView = NSHostingView(rootView: SettingsView())
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// An `.accessory` app with no windows left still counts as active, and the
  /// next copy would then be attributed to ClipFlow rather than to the app the
  /// user is actually typing in (`source_bundle_id`).
  func windowWillClose(_ notification: Notification) {
    NSApp.hide(nil)
  }
}

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
      ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
      ExclusionSettings().tabItem { Label("Excluded Apps", systemImage: "hand.raised") }
      VaultSettings().tabItem { Label("Vault", systemImage: "lock") }
    }
    .padding(14)
    // Taller than it was: the Shortcuts tab now lists the seven fixed panel keys
    // on top of the ten recorders, and at 470 the pin slots were already cut off
    // mid-list with no hint there was more below.
    .frame(width: 480, height: 560)
  }
}

private struct GeneralSettings: View {
  /// Re-read rather than stored: `SMAppService` state can change outside the app
  /// (System Settings › Login Items), so a value cached at first draw goes stale.
  @State private var loginStatus = LaunchAtLogin.status
  @State private var paused = PasteboardMonitor.shared.isPaused

  var body: some View {
    Form {
      Section {
        Toggle("Launch ClipFlow at login", isOn: Binding(
          // `.requiresApproval` reads as on: the user asked for it and the
          // request is filed. The caveat below says what is still missing.
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: {
            LaunchAtLogin.set($0)
            loginStatus = LaunchAtLogin.status
          }
        ))
        if let caveat = LaunchAtLogin.caveat(for: loginStatus) {
          HStack {
            Text(caveat).font(.caption).foregroundStyle(.secondary)
            if loginStatus == .requiresApproval {
              Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                .controlSize(.small)
            }
          }
        }
      }

      Section {
        // FR-7.4. The same switch the status menu flips — one setter, so the
        // menu bar icon and this checkbox can never disagree.
        Toggle("Pause capture", isOn: Binding(
          get: { paused },
          set: { PasteboardMonitor.shared.setPaused($0) }
        ))
      } footer: {
        Text("Nothing is recorded while paused, and the menu bar icon is dimmed. Pausing survives sleep, wake and quitting.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    // The menu can pause too, and the status item's own "Ignore Next Copy" can
    // be spent while this window is open.
    .onReceive(NotificationCenter.default.publisher(for: .clipFlowCaptureStateChanged)) { _ in
      paused = PasteboardMonitor.shared.isPaused
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      loginStatus = LaunchAtLogin.status
    }
  }
}

/// FR-6.2. The recorders are the whole feature: `KeyboardShortcuts` stores the
/// binding itself, so nothing here reads or writes a preference.
///
/// This also retires a real papercut. A default written in code only applies on
/// a machine that has never run the app — after that the stored value wins, and
/// the only fix was `defaults delete com.jayyy044.clipflow KeyboardShortcuts_…`
/// from a terminal. "Restore Defaults" is that command, in the app.
private struct ShortcutSettings: View {
  /// Listed, not bound. These are `onKeyPress` handlers in `HistoryView` and one
  /// `performKeyEquivalent` in `Panel` — there is no `KeyboardShortcuts.Name`
  /// behind them, so there is nothing for a `Recorder` to record into, and making
  /// them rebindable would mean a second parallel storage and conflict system for
  /// keys that have no conflicts.
  ///
  /// Showing them is worth it anyway: nothing in the UI ever claimed these
  /// existed, which is how Option+Delete shipped broken for the whole project
  /// without anyone noticing it had never once worked (D-28).
  ///
  /// Source of truth is `HistoryView`'s key handling; this is a description of
  /// it, and drifts if that changes.
  private static let panelBindings: [(keys: String, action: String)] = [
    ("↩", "Paste the selected item"),
    ("⇧↩", "Paste as plain text"),
    ("↑ ↓", "Move through the list"),
    ("⌥P", "Pin or unpin the selected item"),
    ("⌥⌫", "Delete the selected item"),
    ("⌘O", "Open a link in the selected item"),
    ("⌥V", "Open the vault"),
    ("⎋", "Close the window"),
  ]

  var body: some View {
    Form {
      Section("Open ClipFlow") {
        KeyboardShortcuts.Recorder("Show history", name: .toggleHistory)
      }
      Section {
        ForEach(Self.panelBindings, id: \.keys) { binding in
          LabeledContent(binding.action) {
            Text(binding.keys)
              .font(.body.weight(.medium))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .liquidGlass(in: .rect(cornerRadius: 6))
          }
        }
      } header: {
        Text("In the History Window")
      } footer: {
        Text("Fixed, not rebindable. Typing filters the list as you go, and clicking a row pastes it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section {
        ForEach(Array(KeyboardShortcuts.Name.pasteSlots.enumerated()), id: \.offset) { index, name in
          KeyboardShortcuts.Recorder("Paste slot \(index + 1)", name: name)
        }
      } header: {
        Text("Pin Slots")
      } footer: {
        Text("Each slot pastes its pinned item without opening ClipFlow")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section {
        Button("Restore Defaults") {
          KeyboardShortcuts.reset([.toggleHistory] + KeyboardShortcuts.Name.pasteSlots)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Vault export and import. In Settings and nowhere else, deliberately: the panel
/// is one keystroke from normal use, and the export file is the one artifact in
/// the whole design that is neither device-bound nor Touch ID gated. Whoever has
/// it and the key has the entire vault, on any machine, forever.
private struct VaultSettings: View {
  /// Off by default and phrased as an override, not a peer. A generated key is
  /// 128 random bits and has nothing to guess; a typed passphrase is worth only
  /// its own entropy, and the KDF buys less time than it sounds like — 600k
  /// PBKDF2 iterations measure ~68 ms on this machine, so an offline attacker
  /// gets a lot of guesses per second.
  @State private var useOwnPassphrase = false
  @State private var notice: String?
  /// Both flows run Touch ID, 600k PBKDF2 iterations and a modal panel. Without
  /// this a second click starts a second export on top of the first.
  @State private var busy = false

  /// Every way out of the generated-key flow before a file exists. It has to say
  /// the key is dead, not just that nothing was written: the user is holding a
  /// piece of paper and the next attempt generates a different key.
  private static let discardedKeyNotice =
    "Export cancelled. No file was written, and the recovery key you were just shown is not in use — the next export generates a different one."

  var body: some View {
    Form {
      Section {
        Text("An export is every vault entry in one file, encrypted with a key that is not your Mac's. Anyone who gets both the file and the key has your whole vault, on any machine, forever. There is no expiry and no way to revoke it.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Text("Before you export")
      }

      Section {
        Toggle("Use my own passphrase instead", isOn: $useOwnPassphrase)
        Text(useOwnPassphrase
          ? "Weaker than the generated key unless yours is long and random. Minimum 12 characters."
          : "ClipFlow generates a recovery key and shows it once. Write it down — without it the file cannot be opened, by you or by anyone.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Export Vault…") { Task { @MainActor in await exportVault() } }
          .disabled(busy)
      } header: {
        Text("Export")
      } footer: {
        // The other half of the section above. That one says what an export costs;
        // without this one, nobody reading it ever makes the file, and the vault's
        // keys do not leave this Mac.
        Text("An export is also the only backup. Vault entries are sealed to this Mac and cannot be recovered from a backup of the app's files, so erasing, repairing or replacing it leaves nothing to restore from except a file you exported first.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Import Vault…") { Task { @MainActor in await importVault() } }
          .disabled(busy)
      } header: {
        Text("Import")
      } footer: {
        Text("Merges into what is already here. Nothing is replaced or deleted, and a wrong key fails without touching your vault.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let notice {
        Section {
          Text(notice).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Unlock (export reads every secret), then the key, then the panel. The
  /// acknowledgement is collected *before* the file exists: nothing outside this
  /// view enforces it, and an unacknowledged key is an export nobody can ever
  /// open.
  @MainActor
  private func exportVault() async {
    notice = nil
    busy = true
    defer { busy = false }
    do {
      try await VaultSession.shared.unlock()
      // Everything from here to the write is modal, and a `.common` idle timer
      // fires inside `.modalPanel` run loops — so without this the vault can
      // lock while the user is copying 32 characters onto paper, and `export`'s
      // own `isUnlocked` check then refuses, after the key has been shown and
      // discarded. Suspended *after* `unlock()`, which arms the timer itself.
      // The `defer` covers every exit: the cancels below, a throw, and the
      // success path. A suspension that leaked would leave the vault unlocked
      // with nothing left to close it.
      VaultSession.shared.suspendIdleTimer()
      defer { VaultSession.shared.resumeIdleTimer() }

      let passphrase: String
      if useOwnPassphrase {
        guard let typed = askSecret(
          title: "Choose a passphrase for this export",
          message: "This is the only thing protecting the file. At least \(VaultTransfer.minimumPassphraseLength) characters, and there is no way to recover it.",
          confirm: "Continue"
        ) else { return }
        // Checked here rather than left to `makeFile` only so the user is not
        // asked where to save a file that was never going to be written.
        guard typed.count >= VaultTransfer.minimumPassphraseLength else {
          notice = VaultTransfer.Failure.passphraseTooShort.localizedDescription
          return
        }
        // The generated key gets an acknowledgement step because a key nobody
        // wrote down is a file nobody can open. A typed passphrase has exactly
        // the same failure, one typo away, and it surfaces at restore time when
        // the file is the only copy — so it is typed twice.
        guard let again = askSecret(
          title: "Enter the passphrase again",
          message: "A typo here cannot be spotted later. A file sealed with the wrong passphrase cannot be opened by anyone, including you.",
          confirm: "Continue"
        ) else { return }
        guard again == typed else {
          notice = "The two passphrases did not match. No file was written."
          return
        }
        passphrase = typed
      } else {
        passphrase = try VaultTransfer.generateRecoveryKey()
        guard acknowledgeRecoveryKey(passphrase) else {
          notice = Self.discardedKeyNotice
          return
        }
      }

      let panel = NSSavePanel()
      panel.nameFieldStringValue = VaultTransfer.defaultFilename()
      if let type = UTType(filenameExtension: VaultTransfer.fileExtension) {
        panel.allowedContentTypes = [type]
      }
      // Silence here was the worst of them: the user has just written down a key
      // and the window would simply go quiet, leaving nothing to say whether the
      // key is now live somewhere.
      guard panel.runModal() == .OK, let url = panel.url else {
        notice = useOwnPassphrase ? "Export cancelled. No file was written." : Self.discardedKeyNotice
        return
      }

      let data = try await VaultTransfer.export(passphrase: passphrase)
      try data.write(to: url, options: .atomic)
      notice = "Exported to \(url.lastPathComponent)."
    } catch {
      // Every throw on this path ends up here. A failure that left the button
      // looking like it worked would be the same defect the dead stub was.
      notice = error.localizedDescription
    }
  }

  /// The file, then the key, then Touch ID. The raw string goes straight through
  /// — no shape check here on purpose: `VaultTransfer` already folds case,
  /// dashes, spaces and the Crockford 0/O and 1/I/L confusions, and a length or
  /// grouping rule written against a remembered example is how a UI ends up
  /// rejecting every valid key. Merging is `VaultTransfer`'s job, not this one's.
  @MainActor
  private func importVault() async {
    notice = nil
    busy = true
    defer { busy = false }
    do {
      // Same modal-loop problem as the export. Here the vault may already be
      // unlocked from an earlier action, and its countdown would run out under
      // the open panel and the key prompt — costing a second Touch ID sheet at
      // best and `importFile`'s `.locked` at worst. Suspended before the first
      // panel; the `defer` resumes on the cancels, on a throw and on success.
      VaultSession.shared.suspendIdleTimer()
      defer { VaultSession.shared.resumeIdleTimer() }

      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      if let type = UTType(filenameExtension: VaultTransfer.fileExtension) {
        panel.allowedContentTypes = [type]
      }
      panel.prompt = "Import"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      let data = try Data(contentsOf: url)

      guard let passphrase = askSecret(
        title: "Enter the recovery key or passphrase",
        message: "For a recovery key, capitals, dashes and spaces do not matter.",
        confirm: "Import"
      ) else { return }

      try await VaultSession.shared.unlock()
      let result = try await VaultTransfer.importFile(data, passphrase: passphrase)
      notice = "Imported \(result.imported), skipped \(result.skipped) already in your vault."
    } catch {
      notice = error.localizedDescription
    }
  }

  /// One secure field in a modal alert. Returns the raw string, untrimmed and
  /// unvalidated; nil means the user cancelled.
  @MainActor
  private func askSecret(title: String, message: String, confirm: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  /// Shown once, before anything is written. No "copy to clipboard" button: this
  /// is a clipboard manager, and the one place a recovery key must not land is
  /// the history it would be captured into.
  @MainActor
  private func acknowledgeRecoveryKey(_ key: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Write down your recovery key"
    alert.informativeText = "It is shown once and stored nowhere. Without it the export cannot be opened, by you or by anyone. No file is written until you confirm."
    let field = NSTextField(labelWithString: key)
    field.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
    field.isSelectable = true
    field.sizeToFit()
    alert.accessoryView = field
    alert.addButton(withTitle: "I wrote it down")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}

/// FR-7.2, "managed in Settings by picking apps" — so the picker is `NSOpenPanel`
/// filtered to applications, not a text field for bundle ids.
private struct ExclusionSettings: View {
  @State private var excluded = Preferences.excludedBundleIDs.sorted()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nothing copied while one of these apps is frontmost is recorded.")
        .font(.callout)
        .foregroundStyle(.secondary)

      List {
        ForEach(excluded, id: \.self) { bundleID in
          HStack(spacing: 8) {
            Image(nsImage: AppIcon.forBundleID(bundleID))
              .resizable()
              .frame(width: 18, height: 18)
            // The bundle id is the fallback, not the label: an excluded app that
            // has since been uninstalled still has to be identifiable and
            // removable.
            Text(Self.name(for: bundleID) ?? bundleID)
            Spacer()
            Button {
              excluded.removeAll { $0 == bundleID }
              Preferences.excludedBundleIDs = Set(excluded)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Stop excluding this app")
          }
        }
      }
      .overlay {
        if excluded.isEmpty {
          Text("No apps excluded").foregroundStyle(.tertiary)
        }
      }

      Button("Add App", action: pickApps)
    }
    .padding(4)
  }

  private func pickApps() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Exclude"
    guard panel.runModal() == .OK else { return }

    var set = Preferences.excludedBundleIDs
    for url in panel.urls {
      // An app with no bundle identifier can never match a captured
      // `sourceBundleID`, so storing it would be an entry that does nothing.
      guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
        NSLog("ClipFlow: \(url.lastPathComponent) has no bundle identifier; not excluded")
        continue
      }
      set.insert(bundleID)
    }
    Preferences.excludedBundleIDs = set
    excluded = set.sorted()
  }

  private static func name(for bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path)
  }
}
