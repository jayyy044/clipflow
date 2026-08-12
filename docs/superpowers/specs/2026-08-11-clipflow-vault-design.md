# ClipFlow Vault — design

Date: 2026-08-11
Status: approved, not yet implemented
Base commit: `e1fcf12`

## Problem

ClipFlow stores clipboard text in plaintext in SQLite and indexes it for search.
Three gates catch *some* secrets today, all in `Sources/ClipFlow/Capture/PasteboardMonitor.swift`:

1. `skipTypes` (`:13`) — `org.nspasteboard.ConcealedType`, set by 1Password / Bitwarden /
   Apple Passwords when you use *their* copy button.
2. `looksLikeCredential` (`:431`) — issued tokens by prefix (`ghp_`, `sk-ant-`, `AKIA`,
   `xoxb-`, …) plus PEM `PRIVATE KEY` blocks. Requires a bare token: ≥20 chars, no whitespace.
3. `Preferences.excludedBundleIDs` (`:316`) — user-chosen apps, fails closed across the
   whole poll window.

Not caught, and verified stored in plaintext on 2026-07-31: a plain password out of
`pass`, `gpg --decrypt`, or `echo $PW | pbcopy`. No pasteboard type tag, no shape to match.
Entropy scoring was considered and rejected — it also flags UUIDs, hashes, base64, and a
clipboard manager that silently eats things you meant to keep stops being trusted.

The Vault is the deliberate place for that class of secret: things you want to *keep* and
retrieve, encrypted at rest, gated behind Touch ID — your SSN, a bank PIN, a passport
number, a recovery code.

## Constraints

- Swift 6 toolchain, **Swift 5 language mode**, macOS 15 minimum (`Package.swift`).
- **No new dependencies.** NFR-3 caps the project at two and both are spent (GRDB 7,
  KeyboardShortcuts). CryptoKit and CommonCrypto are system frameworks and do not count.
- GRDB 7, `DatabaseQueue`, WAL, `DatabaseMigrator`. Latest migration is `v8_rtf`.
- No test target exists. The self-check is a CLI flag, not a framework.

## Decisions

| # | Decision | Why |
|---|---|---|
| V-1 | Two keys: name key with no access control, value key with `.userPresence` | Locked vault shows real entry names; DB file alone still shows nothing readable |
| V-2 | Separate `vault_entries` table, never a flag on `items` | FTS triggers at `Database.swift:299-321` would index secrets in plaintext |
| V-3 | Auth is the access control on the key, never an `if` on `LAContext` | A boolean return is patchable; a key agreement the Enclave refuses is not |
| V-4 | Hardened runtime on the signature | Blocks non-root `task_for_pid`; the single biggest real reduction in memory exposure |
| V-5 | Vault values are typed, not pasted | The general pasteboard is world-readable; `keyboardSetUnicodeString` skips it entirely |
| ~~V-6~~ | ~~No Secure Enclave key in v1~~ — **REVERSED 2026-08-11 after measurement**, see Unit A | The Keychain is entitlement-blocked for this build and the legacy fallback silently drops the gate; the Enclave is the only path where `.userPresence` is actually enforced |
| V-7 | Export is one sealed file, not a zip | ZipCrypto is broken, AES-zip is patchy, and there is nothing to archive |
| V-8 | Export key derives from a passphrase, never from device keys | Exporting the device key would make the file equivalent to the vault |

## Threat model — stated honestly

**Defended:** the DB file on its own (backups, Time Machine, a synced folder, someone
poking with `sqlite3`); another process reading our memory, once V-4 lands; the vault value
appearing on the system pasteboard, via V-5.

**Not defended:** root. While the vault is unlocked the value key is in this process's
memory, and to *show* you a secret the app must hold that secret. No design fixes that.
V-4 shrinks who can look; V-5 shrinks where it goes; the idle timeout shrinks how long.

**The export file** is the one artifact that is neither device-bound nor Touch ID gated.
Whoever has it and the passphrase has the whole vault, on any machine, forever. That is
inherent to wanting transfer. Mitigations: explicit action only, never automatic, Touch ID
gated to produce, blunt warning in the UI.

---

## Unit A — keys and session

New: `Sources/ClipFlow/Vault/VaultKeys.swift`, `Sources/ClipFlow/Vault/VaultSession.swift`

### VaultKeys

**Corrected 2026-08-11, after measurement. V-6 is REVERSED.** The section below originally
specified two Keychain generic-password items with `kSecUseDataProtectionKeychain: true`.
That design does not work on this build, and the obvious fallback is actively dangerous.
Both were measured on this machine, signed with the real `make bundle` command line:

- **Data-protection keychain:** `SecItemAdd` returns **-34018 `errSecMissingEntitlement`**.
  The entitlements that would fix it are restricted ones requiring an embedded provisioning
  profile, which a command-line `codesign` build does not have — adding them SIGKILLs the
  app at launch. There is no version of Unit A that ships on this path.
- **Legacy file keychain:** `SecItemAdd` **succeeds**, and `SecItemCopyMatching` then returns
  the key data **with no authentication prompt at all**. The `.userPresence` access control
  is accepted and ignored. This is worse than useless: a vault that looks gated and is not.
  Do not go there under any circumstances.

So the keys are bound to the **Secure Enclave** instead. Measured, same signing, on this
machine:

- `SecureEnclave.isAvailable` → `true`
- `SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl:)` creates successfully with an
  entitlements file that grants nothing
- `.dataRepresentation` persists to a file and reconstructs in a **separate process run** —
  re-measured end to end in the envelope format below, `0600`, 669-byte blob, and the master
  key it unwraps opens a box sealed by the first process. Size varies with the access
  control: 324 bytes for the name key's `.privateKeyUsage`, 335 in the earlier note
- a key agreement against a key whose access control is `.userPresence` **fails headless**
  with `com.apple.LocalAuthentication` **-1009**, "Operation is not allowed" — the gate being
  ENFORCED
- the identical flow with `.privateKeyUsage` and no user presence **succeeds**, which is the
  control proving the line above is the ACL and not a broken call

V-6's original reasoning ("only helps a root snapshot attacker; most code of the options;
fails on pre-T2 Intel") is superseded on the first two counts — it is now the *only* place
`.userPresence` is enforced, and it is comparable in size to the Keychain version. The third
count stands: `SecureEnclave.isAvailable == false` on pre-T2 Intel, and there the vault
reports `.unavailable` and does not open. That is accepted.

#### Shape

Two Secure Enclave `P256.KeyAgreement` private keys, both
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — device-bound, out of iCloud Keychain and out
of Time Machine.

| key file | access control | prompts |
|---|---|---|
| `vault-name.key` | `.privateKeyUsage` | no |
| `vault-value.key` | `.userPresence` | Touch ID, falls back to Mac password |

The value key's access control, unchanged from the original spec:

```swift
SecAccessControlCreateWithFlags(
  nil,
  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
  .userPresence,
  &error)
```

Each file holds an ECIES envelope around a 256-bit `SymmetricKey` master key: the Enclave
key's `.dataRepresentation`, an ephemeral P-256 public key, and the master key sealed under
`HKDF-SHA256(sharedSecret)` with AES-GCM. Written to the app's Application Support
directory, beside the database, created `0600`. The blobs are useless without this machine's
SEP; they are still treated as secrets — never logged, paths never logged at info level.

*Wrapping* uses the Enclave key's **public** half and an ephemeral private key, so creating a
vault never prompts. *Unwrapping* runs the agreement inside the Enclave against the static
private key, and **that** is what raises the authentication sheet. **There must be no code
path that decides whether to prompt.** If the master key comes back, the user authenticated;
if it does not, there is no plaintext. That is V-3 and it is the whole security model — do
not add an `LAContext.evaluatePolicy` gate in front of it. `LocalAuthentication` is imported
in `VaultKeys.swift` for its **error codes only**.

`nameKey()` / `valueKey()` return the unwrapped master key, generated and wrapped lazily on
first use. One prompt per unlock, not per entry — `VaultSession` caches the result.

The public API is unchanged, which is why Units B, C and D did not have to move:

```swift
enum VaultKeys {
  enum Failure: Error { case userCancelled, unavailable, keychain(OSStatus) }

  /// No prompt. Created on first call if absent.
  static func nameKey() throws -> SymmetricKey

  /// Raises Touch ID / password. Created on first call if absent.
  static func valueKey() throws -> SymmetricKey

  /// True if the value key exists — used to tell "vault never set up" from "locked".
  static var isConfigured: Bool { get }
}
```

`keychain(OSStatus)` keeps its now-inaccurate name for source compatibility; it carries the
underlying Security or LocalAuthentication code and means "unclassified failure".

A cancelled sheet maps to `.userCancelled` and must be distinguishable by callers: it is not
an error worth showing an alert for. `SecureEnclave.isAvailable == false`, and the -1009 an
ACL that cannot be satisfied reports, map to `.unavailable`. Everything unrecognised falls
through to `.keychain`, which callers alert on — the safe direction, since silently reading
an unknown failure as "the user changed their mind" would hide a broken vault.

**Unverified, and it must stay marked so:** which code a *user-cancelled* Touch ID sheet
actually reports, and whether Escape reports it as cancel or as `authenticationFailed`. That
needs a GUI session; the collapse of `authenticationFailed` into `.userCancelled`, and the
log line that compensates for it, are carried over from the original spec on the same
unverified premise.

### VaultSession

`@MainActor final class VaultSession`, singleton, holds the unwrapped value key while
unlocked. One prompt per unlock, not per entry.

```swift
@MainActor final class VaultSession: ObservableObject {
  static let shared: VaultSession
  @Published private(set) var isUnlocked: Bool

  func unlock() async throws          // calls VaultKeys.valueKey(), caches it
  func lock()                         // drops the key, posts .clipFlowVaultLocked
  func seal(_ value: String) throws -> Data    // requires unlocked
  func open(_ sealed: Data) throws -> String   // requires unlocked
}
```

Locks on **all** of:

- `com.apple.screenIsLocked` — observe it the same way `PasteboardMonitor.swift:171` does.
- The panel closing.
- A 5-minute idle timer, reset on each vault interaction.

Not relying on `applicationWillTerminate`: per the project notes it fires on
`NSApp.terminate` but **not** on `SIGTERM`, so it cannot be the only backstop. The idle
timer is.

Names use `VaultKeys.nameKey()` directly and do not require an unlocked session.

Both keys seal with `AES.GCM.seal(_:using:)` and store `sealedBox.combined`. GCM
authenticates, so a tampered row fails to open rather than decrypting to garbage — surface
that as a corrupt-entry state, never as empty text.

---

## Unit B — storage

Edited: `Sources/ClipFlow/Storage/Database.swift`
New: `Sources/ClipFlow/Storage/VaultEntry.swift`

### Migration

Register `v9_vault` after `v8_rtf`, following the existing style:

```sql
CREATE TABLE vault_entries (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  sealed_name  BLOB NOT NULL,
  sealed_value BLOB NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
```

**No FTS trigger on this table, and no index.** Both are deliberate and both need a comment
saying so, because the next person to touch this will otherwise "fix" the missing index.
Ciphertext is not indexable, and sorting happens in memory after names decrypt.

`// ponytail: in-memory sort of decrypted names, fine to ~1000 entries`

### Secure delete

Add `PRAGMA secure_delete=ON` in `openMigrated` (`Database.swift:122`), next to the
existing `config.journalMode = .wal`. Without it, moving an item from history into the
vault leaves the plaintext sitting in freed pages of the DB file.

Known gap to comment, not to solve: WAL means deleted content can also persist in the
`-wal` file until a checkpoint. Note it; do not add a checkpoint-on-delete without
measuring what it costs the capture path.

### Record and repository

Match the existing `Item` / `ItemRepository` split — records in their own file, every query
in a caseless-enum namespace, failures reported rather than swallowed. Follow
`counts()`'s precedent: an optional return means *unknown*, not zero, and callers must bail
rather than substitute a number.

```swift
struct VaultEntry: Codable, FetchableRecord, MutablePersistableRecord {
  var id: Int64?
  var sealedName: Data
  var sealedValue: Data
  var createdAt: Int64
  var updatedAt: Int64
}

enum VaultRepository {
  @discardableResult static func save(_ entry: inout VaultEntry) -> Bool
  static func all() -> [VaultEntry]?          // nil = read failed, not "empty"
  static func entry(id: Int64) -> VaultEntry?
  @discardableResult static func delete(id: Int64) -> Bool
  static func count() -> Int?
}
```

---

## Unit C — export and import

New: `Sources/ClipFlow/Vault/VaultTransfer.swift`
Depends on: A, B

### File format

Extension `.clipflowvault`. JSON header in the clear — the salt and KDF parameters must be
readable to derive the key, which is standard and not a leak.

```json
{
  "format": "clipflow.vault.export",
  "version": 1,
  "kdf": "pbkdf2-hmac-sha256",
  "iterations": 600000,
  "salt": "<base64, 32 random bytes>",
  "sealed": "<base64, AES-GCM combined box>"
}
```

Plaintext inside `sealed`, after opening:

```json
[{ "name": "...", "value": "...", "created_at": 1754... }]
```

### Key derivation

`CCKeyDerivationPBKDF` from CommonCrypto — PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP's
current figure), 32-byte random salt, 32-byte derived key.

`// ponytail: PBKDF2 because macOS ships no Argon2id and NFR-3 has no dependency budget
left. Swap if that ever changes — memory-hard is materially better against GPU cracking.`

Run the derivation off the main actor. 600k iterations is deliberately slow.

### Passphrase

Default to a **generated 128-bit recovery key**, shown grouped for transcription, from
`SecRandomCopyBytes`.

**Corrected 2026-08-11.** An earlier draft gave `K7QM-4F2A-9B17-XR3D-88TW-P1LN` as the
example — 24 characters, which is wrong. 128 bits of Crockford base32 is 25.6 characters
and does not divide into six groups of four. The real shape is **26 characters**, six
groups of four plus a trailing pair: `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX`. Keeping all 128
bits beat a tidier line. Any UI must accept 26, and must fold transcription variants back
to canonical form — case, dashes, spaces, and the Crockford `0`/`O` and `1`/`I`/`L`
confusions. A generated key makes the
KDF's strength close to irrelevant because there is nothing to guess. The user may override
with their own passphrase; if they do, enforce a minimum length and say why in the dialog.

### Export

1. Requires an unlocked session — this decrypts everything.
2. Show the recovery key, require an explicit acknowledgement that it was written down.
3. Decrypt all entries in memory, serialize, seal under the derived key.
4. `NSSavePanel`, default filename `clipflow-vault-<yyyy-MM-dd>.clipflowvault`.

The device keys are never written to the file. Only the passphrase opens it.

### Import

1. `NSOpenPanel`, then the passphrase.
2. Derive, open. **A GCM tag failure means wrong passphrase and the UI says exactly that
   and nothing more** — no partial results, no hints about how close it was.
3. Re-seal each entry under *this* machine's keys and insert.
4. **Merge, never replace.** Skip entries whose decrypted name and value both match an
   existing one. A wrong file must not be able to destroy a good vault.

Reject unknown `format` or `version` values before doing any work.

---

## Unit D — UI

New: `Sources/ClipFlow/UI/VaultView.swift`
Edited: `Sources/ClipFlow/UI/Panel.swift`, `Sources/ClipFlow/UI/HistoryView.swift`,
`Sources/ClipFlow/UI/Settings.swift`
Depends on: A, B

### Where things live

**Browse and use** is a mode inside the existing panel — that is the hot path, and
`Paster`'s target-app plumbing already works there.

**Add and edit** is a sheet. The panel closes on focus loss, and typing an SSN into
something that can vanish mid-keystroke is unacceptable. **The panel must stop being
transient while the sheet is up.** This is the known integration wrinkle; solve it
explicitly rather than discovering it in testing.

**Export and import** live in Settings behind a warning, never in the panel, never one
click from normal use.

### Locked state

Entry names render (name key needs no prompt). Values show as `••••••••`. A single Unlock
control raises Touch ID.

### Actions on an entry

| Action | Behaviour |
|---|---|
| Use | Types the value into `Paster.targetApp`. Pasteboard untouched. Unit F. |
| Reveal | Shows plaintext in place so the value can be read and backed up. Re-hides on lock. |
| Copy anyway | Explicit and visually secondary. Sets `ConcealedType`, calls `PasteboardMonitor.shared.ignore(changeCount:)`, clears the pasteboard after 60s. |
| Rename / Edit | Re-seals. |
| Delete | Removes the row. |

### Move from history

Context menu item on a history row → prompt for a name, prefilled from the item's preview →
seal → insert into `vault_entries` → `ItemRepository.delete(id:)`, which fires
`items_fts_ad` and purges the FTS posting.

Order matters: **insert into the vault first and confirm it succeeded, then delete.** The
reverse loses the item if the seal fails.

---

## Unit E — build hardening

Edited: `Makefile`
New: `Resources/ClipFlow.entitlements`

`Makefile:55-56` currently signs with no hardened runtime, so any process running as you
can attach and read its memory.

**Corrected 2026-08-11, after measurement.** An earlier draft of this section claimed the
build "carries `get-task-allow`". It does not — re-signing a copy with the exact
pre-change command line returns an empty entitlement dict and `flags=0x0(none)`.
Command-line `codesign` never injects that entitlement; it is Xcode's Debug-configuration
behaviour. The gap is solely the absent hardened-runtime flag, and that flag alone is what
blocks the attach, verified against an unhardened control that *does* let `lldb` in. The
fix below was right; the reason given for it was not.

Add:

```make
codesign --force --sign "$(SIGN_ID)" --options runtime \
  --entitlements Resources/ClipFlow.entitlements $(APP)/Contents/MacOS/ClipFlowOCR
codesign --force --sign "$(SIGN_ID)" --options runtime \
  --entitlements Resources/ClipFlow.entitlements --identifier $(BUNDLE_ID) $(APP)
```

Nested-first ordering is unchanged and the existing comment already explains it.

The entitlements file must **not** contain `com.apple.security.get-task-allow`. Start
empty; add only what a build failure proves is needed.

`SIGN_ID` falls back to ad-hoc (`-`) on a machine without a Development certificate
(`Makefile:15-16`). Whether hardened runtime enforces the anti-debug property under an
ad-hoc signature is **unverified** — this is the one claim in this spec that must be tested
before anyone repeats it:

```
make bundle install && open -a ClipFlow
lldb -p $(pgrep -x ClipFlow)      # must refuse to attach
```

If ad-hoc does not enforce it, say so plainly and record it — do not quietly downgrade the
claim and move on.

Also verify the Accessibility grant survives: per `Makefile:8-13` the grant is keyed on
bundle id plus signing identity, and changing signing options may invalidate it.

---

## Unit F — typing instead of pasting

Edited: `Sources/ClipFlow/Actions/Paster.swift`

Today `Clipboard.copy` writes `NSPasteboard.general` and `Paster.paste()` sends Cmd+V
(`Paster.swift:10`). For a vault value that makes the secret world-readable for as long as
it sits there.

Add a sibling that types the string directly:

```swift
static func type(_ text: String)
```

`CGEvent(keyboardEventSource:virtualKey:keyDown:)` with
`keyboardSetUnicodeString(stringLength:unicodeString:)`, chunked — the buffer is bounded,
so send in runs of ~20 UTF-16 units rather than one call.

Reuse `paste()`'s existing preconditions verbatim; do not re-derive them:

- The 200 ms double-fire guard (`Paster.swift:70`).
- `isTrusted` / `AXIsProcessTrusted` (`:49`).
- `IsSecureEventInputEnabled()` (`:78`) — synthetic keystrokes are swallowed under secure
  input. Same limitation the existing paste path already has, so this is not a regression,
  but the failure must be explained rather than silent.
- The frontmost-app settle (`:33`) and `targetApp` capture (`:15`).

Never log the typed string.

---

## Self-check

No test target exists and this spec does not add one. Add a `--vault-self-check` argument,
handled early in `Sources/ClipFlow/main.swift`, that runs asserts against a temporary
in-memory database and exits with a non-zero status on failure.

Four assertions, the third being the one that matters most:

0. **Added 2026-08-11 with the V-6 reversal.** A Secure Enclave key is created, its blob is
   written `0600`, and it is reconstructed from that blob in-process and shown to produce the
   same master key. Run against the *name* key, which has no user-presence ACL, so it needs
   no sheet and runs headless. This replaces the earlier data-protection-keychain probe,
   which asserted a path that is now known to return -34018. **The value key's Touch ID path
   is not asserted and cannot be** — headless it fails with -1009, which is the gate working.
1. Seal then open round-trips a string.
2. A tampered sealed blob fails to open — it does not return garbage.
3. **Inserting a vault entry leaves `items_fts` empty.** This is what catches a future
   "simplification" that folds the vault back onto the `items` table.
4. Export then import under a *different* pair of device keys reproduces the same names and
   values, and a wrong passphrase fails cleanly.

## Out of scope

- Images in the vault. Text only; images would need a parallel encrypted path through
  `ImageStore`.
- Any automatic classification of copies as secret. Entropy scoring was already considered
  and rejected; nothing here revisits that.
- Search over vault contents. Ciphertext is not searchable and adding a plaintext index
  would undo the entire design.
- Syncing between machines beyond the manual export file.

## Build order

| Wave | Units | Notes |
|---|---|---|
| 1 | A, B, E, F | Genuinely independent |
| 2 | C, D | Consume A and B |
| 3 | self-check, then build + `lldb` verification | |
