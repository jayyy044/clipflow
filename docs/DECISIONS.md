# Decisions

Resolved questions from PRD v1. Recorded so they don't get re-argued.

---

## D-1: Build strategy — Path A (greenfield)

PRD §10 recommended Path B (fork Maccy). **Rejected on evidence.**

Inspected `p0deje/Maccy` @ HEAD (2026-07-29, MIT, Copyright (c) 2025 Alex Rodionov):

| Finding | File | Conflicts with |
| --- | --- | --- |
| SwiftData `ModelContainer`, not raw SQLite | `Storage.swift:30` | FR-2.1, and FTS5 is unreachable through SwiftData |
| Image bytes stored as `Data` in the model | `Models/HistoryItemContent.swift:7` | FR-2.2 (never blob images) |
| Search is `Fuse` fuzzy over an in-memory array, limit 5000 | `Search.swift:37-38` | FR-3.1, FR-3.3 (FTS5 + BM25) |
| `load()` fetches all items into RAM as decorators | `Observables/History.swift:106` | NFR idle-memory budget at scale |
| 9 dependencies incl. **Sparkle** (network) | `Package.resolved` | NFR-3 (two deps max), FR-7.1 (zero network) |

Path B was premised on "Phases 0–6 and 9 already done." True of the behavior,
false of the storage and search layers — which is exactly where the
differentiator (one FTS5 index over both `content` and `ocr_text`) has to live.
Grafting OCR search onto SwiftData means rewriting Phases 1 and 3, the two
phases Path B was supposed to skip.

### Harvest, don't fork

Maccy is MIT. Copy individual files with an attribution header; do not vendor
the repo. Reference clone stays outside the tree (`reference/`, gitignored).

| File | What it solves |
| --- | --- |
| `Clipboard.swift` | `changeCount` poll loop, concealed/transient/auto-generated type set |
| `FloatingPanel.swift` | `NSPanel` + `.nonactivatingPanel` window that doesn't steal focus |
| `Accessibility.swift` | Accessibility permission flow |
| `KeyboardLayout.swift` | HP-4, non-QWERTY layouts |
| `HistoryItemAction.swift` | paste injection |

---

## D-2: Window layer — `NSStatusItem` + `NSPanel`, not `MenuBarExtra`

PRD FR-6.1 says `MenuBarExtra`. Overridden.

`MenuBarExtra(.window)` gives weak control over activation, focus, and key
handling — the three things FR-6.2 (hotkey open), FR-6.5 (keyboard nav, Esc),
and HP-2 (reactivate previous frontmost app before synthesizing Cmd+V) all
require. It also cannot read modifier flags on the icon click, which FR-7.3
("ignore next copy") needs.

Maccy independently landed here: `NSStatusItem` in `AppDelegate.swift:11` plus
`FloatingPanel: NSPanel` with `.nonactivatingPanel` in `FloatingPanel.swift:27`.
`MenuBarExtra` appears only as a hidden shim in `MaccyApp.swift:13`.

Decide this at Phase 0 — retrofitting after Phase 6 means rewriting the window
layer.

---

## D-3: `Option+1..9` binds to `pin_slot`, not list position

PRD FR-5.2 specified both readings ("paste item N" vs "stable 1..9 for pinned
shortcuts") and Phase 5's acceptance criterion assumed the positional one.

Positional is useless: the target moves every time anything is copied. Stable
slots are the entire point of pinning. Phase 5 acceptance criterion needs
rewording.

---

## D-4: Pinned items — section when idle, boost when searching

FR-3.3 (BM25 boost) and FR-6.3 (separate section) unqualified means a pinned
match renders twice.

- Empty query: pinned section above the flat list.
- Non-empty query: one flat ranked list, pinned boosted above unpinned.

---

## D-5: Open questions (PRD §11), answered

1. **Pinned in search** — ranked above, not excluded. See D-4.
2. **File items** — reference the path only. Copying files into app storage is
   unbounded disk growth for a rarely-used feature. Stale reference degrades
   gracefully: grey the row, show "file moved".
3. **OCR from excluded apps** — doesn't arise, no capture happens.
4. **Retention default** — keep 1000. The number was never the risk; unbounded
   *item size* is (see S-5). Cap the size and 1000 is fine.
5. **Browser picker** — cut it. System default browser, `NSWorkspace.shared.open(url)`,
   one line. A Settings pane for a preference nobody changes.

---

## D-6: The memory budget is `phys_footprint`, not RSS

NFR "idle resident memory < 60 MB" is ambiguous, and the two readings disagree
at Phase 2 with an empty database:

```
rss            = 63.6 MB    over budget
phys_footprint = 20 MB      under budget
```

RSS counts every physical page mapped into the process, including AppKit,
SwiftUI, and Foundation pages that come from the system dyld shared cache and
exist whether ClipFlow runs or not. `phys_footprint` counts what is actually
attributable to us and is what Activity Monitor's "Memory" column reports.

Read literally as RSS, the budget rules out SwiftUI entirely — linking it at all
maps tens of MB of shared framework pages. So the budget is `phys_footprint`,
measured with `footprint -p $(pgrep -x ClipFlow)`.

Provisional: recorded with reasoning rather than agreed. Revisit if the intent
really was RSS, because that changes the UI framework choice, not the code.

---

## D-7: Footprint research — what was checked and rejected

Investigated once so it isn't re-derived. Maccy was read as the reference
implementation rather than trusting general advice.

**Rejected, already correct or not worth it:**

| Idea | Why not |
| --- | --- |
| `-Osize`, `-static-stdlib`, explicit dead-strip, LTO | SPM `-c release` already gives `-O` + wholemodule + dead-strip, which is exactly what Maccy ships (`project.pbxproj:1719-1720`). `-static-stdlib` would *raise* unique RSS by un-sharing the stdlib. |
| Tear down the panel's `NSHostingView` on close | Maccy keeps its `contentView` resident permanently (`FloatingPanel.swift:56-66`, `close()` only hides). Low single-digit MB, not where the budget goes. |
| `DispatchSourceTimer` / `NSBackgroundActivityScheduler` | No measurable win over a tolerance'd `Timer`. Maccy sets *no* tolerance at all (`Clipboard.swift:51-59`), so ours is already stricter. |
| `cache_size` / `mmap_size` tuning | GRDB sets neither; SQLite defaults are fine at this scale. |
| `DatabasePool` instead of `DatabaseQueue` | Single writer, single reader. Queue is correct and lighter. |
| `Configuration.automaticMemoryManagement` | Defaults true but is `#if`-gated to iOS/tvOS/watchOS. No effect on macOS. |

**Deferred:**

- Move `Database.shared` and `History.shared` init off the synchronous launch
  path so the status item appears before migrations run. Sub-millisecond today;
  matters once the database grows or a migration lands.
- `NSBackgroundActivityScheduler` A/B against `powermetrics`, if idle energy ever
  becomes a real complaint.

---

## Spec fixes to fold into the code

Ordered by the phase they belong in. Each is a latent bug in PRD v1, not a
nice-to-have.

### Phase 1 (capture + store)

- **S-1. Poller captures its own paste.** `Paster` writes to the pasteboard,
  `changeCount` increments, the poller inserts a duplicate row and the history
  reshuffles on every paste. `ItemRepository` must record the `changeCount`
  produced by its own write and the poller must skip that value. Belongs in
  Phase 1 even though pasting arrives in Phase 4.
- **S-2. Concealed-type race.** Password managers `declareTypes` then `setData`.
  A 500 ms poll can land between the two: the string is readable,
  `ConcealedType` is not yet declared, and the password gets inserted silently.
  On detecting a change, re-read `changeCount` after a short settle (~50–100 ms)
  and only capture if it held. Also treat `IsSecureEventInputEnabled()` as a
  skip signal.
- **S-3. G5 is overpromised.** `ConcealedType` is not set by `pass`, `gpg`,
  `echo $TOKEN`, `kubectl get secret`, or several browser autofill paths.
  "Never records credentials" is true only for apps that mark concealed, plus
  the exclusion list. Documented limit, not a solved problem.
- **S-4. No max item size.** `cat huge.log | pbcopy` puts tens of MB into SQLite
  and FTS in one copy, breaking both the 5 MB DB budget and the 60 MB memory
  budget. Cap at ~1 MB; skip or truncate above. Same cap gates `NSDataDetector`.
- **S-5. `last_used_at` is written and never read.** FR-1.3 bumps it on a dedupe
  hit; FR-3.4 sorts by `copied_at`. Re-copying a three-day-old item leaves it
  buried. Sort by `max(copied_at, last_used_at)`.
- **S-6. Timestamp resolution.** `copied_at` in whole seconds with no tie-break
  makes same-second ordering arbitrary, so the list flickers between queries.
  Milliseconds, and tie-break `id DESC` regardless.

### Phase 3 (search)

- **S-7. FTS5 MATCH injection.** The target user copies error messages. A query
  containing `(`, `"`, `:`, `*`, or a bare `NOT`/`OR` raises a syntax error, not
  zero results — the search field breaks on ordinary developer text. Every term
  must be escaped, double-quoted, and suffixed with `*` for FR-3.2 prefix
  matching. Not optional.
- **S-8. External-content FTS5 triggers.** With `content='items'`, delete and
  update triggers must use the special form carrying the **old** values:
  ```sql
  INSERT INTO items_fts(items_fts, rowid, content, ocr_text)
  VALUES('delete', old.id, old.content, old.ocr_text);
  ```
  Ordinary triggers rot the index silently and search returns deleted rows. Any
  later migration touching those columns needs
  `INSERT INTO items_fts(items_fts) VALUES('rebuild')`.
- **S-9. BM25 column weights.** A screenshot yields hundreds of OCR words; a
  commit hash yields one token. Unweighted length normalization will either bury
  short text items or flood results with screenshots. Needs
  `bm25(items_fts, 1.0, 0.5)` as a knob tuned by feel.
- **S-10. Search should cover `source_app_name`.** "the thing I copied from
  Postico" is a real query and the column already exists.
- **S-11. Seed command.** FR/NFR say "measure them" with no harness, so it never
  happens. One debug action inserting 10k synthetic rows. Phase 3's <50 ms
  acceptance criterion is unverifiable without it.

### Phase 4 (paste)

- **S-12. Capture the previous frontmost app.** HP-2 covers timing but not
  *who*. Record `NSWorkspace.shared.frontmostApplication` **before** showing the
  panel, reactivate it, wait, then post Cmd+V. Otherwise the keystroke lands
  wherever macOS decides, sometimes in our own app.
- **S-13. Stable code signing is a prerequisite, not polish.** Ad-hoc signatures
  change every build, so macOS invalidates the Accessibility grant each rebuild
  and Phase 4 appears broken for reasons unrelated to the code. A free Apple
  Developer account issues a stable "Apple Development" cert. Do it before
  starting Phase 4.

### Phase 6/7 (images, OCR)

- **S-14. Thumbnails have no home.** HP-5 says cache on insert; the schema has no
  column and §7.2 has no module. Write `<uuid>_thumb.png` to disk beside the
  original — survives relaunch, unlike an in-memory `NSCache`.
- **S-15. Name the directory `images.noindex`.** Otherwise Spotlight indexes
  every clipboard screenshot into system-wide search. One character.
- **S-16. Show the matched OCR line on image rows.** Searching "timeout" and
  getting four visually identical terminal thumbnails is not "found it". G3 is
  only half-delivered without a snippet that distinguishes them.
- **S-17. Orphan image sweep on launch.** Row delete and file delete are two
  operations; a crash between them leaks files forever. On launch, list the
  images directory and delete anything no `image_path` references.
- **S-18. Swift 6 strict concurrency.** `VNImageRequestHandler` and `CGImage` are
  Sendable-hostile and `NSPasteboard` is main-actor-adjacent. Start at minimal
  strictness and tighten later rather than paying for it during feature work.

### Phase 9 (privacy, settings)

- **S-19. Suspend the poller on sleep and screen lock.** FR-7.6 only covers
  clearing. Waking twice a second with the lid closed is what shows up in
  battery diagnostics. Maccy does not do this either — grepped, zero hits — so
  there is no reference implementation to copy. Exact hooks:
  - Display sleep: `NSWorkspace.shared.notificationCenter`,
    `screensDidSleepNotification` / `screensDidWakeNotification`
  - System sleep: `NSWorkspace.willSleepNotification` / `didWakeNotification`
  - Screen lock has no public notification. `DistributedNotificationCenter.default()`
    with `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"` —
    undocumented but stable and what this class of app uses.

---

## Cut from v1

- **Phone number detection** (`detected_phones`). Stored, indexed, never
  actioned — FR-5.2 defines no phone shortcut. Dead column. Reinstate when
  there's an action for it.
- **Browser picker.** See D-5.5.
- **FR-7.6 clear-on-screen-lock.** Already optional. Not Phase 9 work.

---

## Known conflicts still open

- **Default hotkey `Cmd+Shift+C` collides with Chrome/Safari inspect-element.**
  It satisfies HP-4 (emits no character) but breaks DevTools for the exact
  target user in §4. Needs a different default. Undecided.
- **No HTML representation is retained.** Browsers put `public.html` alongside
  RTF and plain text; we keep RTF only, so pasting a webpage selection into
  Notion or Slack won't match a direct paste. Accepted for v1 — recorded so it
  doesn't get filed as a bug later.
- **File items are underspecified.** Which column holds the path? Do three files
  selected in Finder become one row or three? `Enter` must write
  `public.file-url`, not the path as text. What is the preview and the icon?
  Resolve before implementing `kind='file'`.
- **`pin_slot` allocation rules are undefined.** What happens on the 10th pin —
  refuse, or pin without a slot? On unpin, is the slot reused by the next pin or
  held? Is the pinned section ordered by slot or by pin time?
