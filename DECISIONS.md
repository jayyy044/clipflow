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

## D-5b: Dedupe is global, superseding FR-1.3

FR-1.3 dedupes only against "the most recent item". That means copying A, then B,
then A again inserts a second row for A, because A was not adjacent. Observed in
real use within an hour of the list existing.

Dedupe is now global on `content_hash`: identical content can only ever occupy
one row, and re-copying it bumps `last_used_at` so it floats back to the top.
Enforced by a UNIQUE index, not just by the repository check, so the invariant
holds even if a future code path forgets.

`copied_at` stays "first seen" and is never rewritten. Ordering and display both
use `max(copied_at, last_used_at)`. Migration `v2_global_dedupe` collapses
pre-existing duplicates, keeping the earliest row and carrying the newest
activity onto it.

Consequence worth knowing: the history can no longer show that you copied the
same string twice. That is the point — the PRD's own non-goals reject anything
that turns retrieval into filing, and a list with three copies of the same commit
hash is worse at retrieval, not better.

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

Settled. For scale, Apple's own ControlCenter — a menu bar utility — measures
105 MB RSS / 77 MB footprint, so it fails a 60 MB budget on either reading. No
SwiftUI app shows a small RSS. ClipFlow at 21 MB sits at a third of budget,
which is where the headroom for thumbnails and the OCR queue comes from.

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

## D-8: OCR configuration, settled by measurement

FR-4.2 specifies `VNRecognizeTextRequest` with `usesLanguageCorrection = true`.
Both halves are overridden. All three configurations were run over rendered
images whose exact text was known, so output could be scored against ground
truth rather than eyeballed.

**`usesLanguageCorrection = false`.** A judgment call on split evidence, not the
clear win an earlier round of testing suggested. Recorded honestly because the
first conclusion here was overconfident.

Round one, three synthetic images of clean rendered code, scored against known
ground truth: OFF won 2, tied 1, never worse.

```
             ON                          OFF
config       jsonpath={•data}            jsonpath={.data}
             RecognizeTextRequest ()     RecognizeTextRequest()
stacktrace   NSURLSession. dataTask(     NSURLSession.dataTask(
```

Round two, 13 real web pages spanning tables, prose, code, charts and dense
documentation: **ON won 8, OFF won 4, 1 tie**, and the split is by content type,
not noise.

```
python docs   ON: "{m," "n}" "af3," "5}"        OFF: "{m,n}" "{m,n}+" "af3,5}"
sqlite docs   ON: "ext/fts"  (drops the 5)      OFF: "ext/fts5"
filesystems   ON: HPF S, VxF$, MES, Kiafs       OFF: HPFS, VxFS, MFS, Xiafs
news article  ON: Wednesday George Figures      OFF: Wodnesday Gearge Fiaures
RFC 9110      ON: readable                      OFF: "2RAnTeCANtaTOE" garbage
```

OFF is kept anyway, for two reasons that outweigh the win count:

**Redundancy asymmetry.** A prose screenshot holds hundreds of words; mangling
10% of them still leaves plenty of correct terms to find it by. A code screenshot
is often worth finding by exactly one token — a version, a hash, `ext/fts5`,
`{m,n}`. Corrupt that token and the screenshot becomes unfindable by the only
thing that identifies it. Failures are equally frequent but not equally costly,
and §4's target user is a developer copying error messages, stack traces and
commit hashes.

**The corpus was degraded in a way real captures are not.** The Chrome extension
emits JPEG only, so every test image carried compression artifacts on small
glyphs. Language correction earns its keep precisely on degraded input — it has
more to repair. ClipFlow captures lossless PNG off the pasteboard, so round two
overstates ON's advantage relative to the real pipeline.

Revisit if the history fills with prose screenshots rather than code. OFF is also
consistently faster: median 0.30s vs 0.48s across the 13.

**`RecognizeTextRequest`, not `VNRecognizeTextRequest`.** macOS 15+, so it costs
no version floor. Same engine, but async/await and Sendable rather than the
Objective-C era callback API that is the reason for S-18.

**`.accurate`, English pinned, `automaticallyDetectsLanguage = false`.** Measured
0.22–0.40s per image against FR-4.6's 1.5s budget, so `.fast` buys latency nobody
perceives at a cost in accuracy that was measured. Language auto-detection on a
terminal screenshot is a coin flip that can select the wrong model.

**`RecognizeDocumentsRequest` rejected — tested on its home turf and it lost.**

macOS 26 only, so it would cost every Sequoia user and add a second code path
behind `if #available`. It was tested specifically on tables, the one category it
exists for, via both the flattened transcript and the structural `document.tables`
API:

| Image | Tables detected | Result |
| --- | --- | --- |
| pricing table | 1 | caught a 1-row table, missed the 7-row main one |
| GDP by country | 1 | 38 rows × 5 cols, but 4 of 5 columns empty — every number gone |
| filesystem comparison | 0 | not detected |
| editor comparison | 0 | not detected |

Flattened, it destroys row association exactly like the others: the pricing table
came back as every Memory/vCPU value, then separately every $/hr value, then
every $/mo — `$0.00595` landing ~40 tokens from `512 MiB`. It is also the slowest
of the three (median 0.55s vs 0.30s).

It fails at the only thing that would justify it. Not deferred — rejected.

---

## D-10: OCR recall collapses on dense tables, in every configuration

Not a configuration problem and not fixable by settings. On dense tabular
screenshots, all three configurations return a small fraction of the visible
text:

```
filesystem comparison table   ~500 words visible   36 / 41 / 38 returned (A/B/C)
GDP table                     dense numeric        67 / 61 / 57 returned
```

Only first-column link text and sidebar chrome survived; Creator, Year and OS
columns were dropped wholesale.

Two hypotheses tested:

- **`minimumTextHeightFraction` is not the cause.** Lowering it to 0.004 produced
  byte-identical output at native size, and actively hurt on upscaled images
  (121 words → 34).
- **Resolution is a partial cause.** Upscaling 2× lifted recall from 41 to 121
  words, 3× to 125 — a 3× improvement that still leaves ~75% of the text unread.

Chart axis labels are worse than useless: every configuration returned noise
(`5848888885`, `1:alj0o0b80`). Charts are not usefully findable by their axis
text.

Consequence for G3: a screenshot of a dense table or a chart may not be findable
by its contents. Screenshots of terminals, code, prose and documentation — the
overwhelming majority of what this app is for — are. Worth stating plainly rather
than discovering later.

Upscaling before recognition is the available lever, and it is not free: memory
is already the tightest budget (D-9) and 2× decode makes it worse. Revisit only
if table screenshots turn out to matter in daily use.

---

## D-9: OCR costs memory that does not fully come back

Recognising a single image, measured on the running app:

```
fresh launch, before any OCR     24 MB
peak during recognition         113 MB   (neural engine 67 MB)
immediately after                54 MB
after 90s idle                   46 MB
```

Against NFR's 60 MB. Two things are true: the **idle** budget — which is what the
NFR actually specifies, and D-6 settled is measured as `phys_footprint` — still
passes at 46–54 MB. And the headroom is now thin, where it used to be a third of
budget.

This is Vision's model, not our queue. A single image costs the same as a
21-image burst, so nothing is accumulating. Isolated measurement put `.accurate`
at 57.8 MB max RSS against `.fast` at 30.8 MB.

Accepted rather than fixed. The two levers both cost more than the problem:
`.fast` trades away accuracy that D-8 measured, and moving Vision into a
short-lived helper process — where the memory is reclaimed when it exits — is a
second executable and IPC plumbing for a budget currently being met.

Revisit if idle after OCR crosses 60 MB, which is the number to watch as
thumbnails and history grow. The helper process is the upgrade path.

---

## D-11: Code signing — free Apple Development identity

Ad-hoc signing has no identity, so the binary's own hash serves as one and macOS
treats every rebuild as an app it has never seen. Since the Accessibility grant
is keyed on bundle id + signing identity, it would have to be re-issued after
every single build — which makes Phase 4 (paste injection) miserable to develop.

Fixed with a free "Apple Development" certificate from a normal Apple ID: Xcode →
Settings → Apple Accounts → add account → Personal Team → Manage Certificates.
No paid Developer Program. Result: `TeamIdentifier=D4YFLFJDBK` instead of
`not set`, stable across rebuilds.

**The actual blocker was not Xcode or the account.** The certificate existed and
its private key was present — signing failed with:

```
unable to build chain to self-signed root for signer "Apple Development: ..."
```

The certificate is issued by `OU=G3`, and only the *original* WWDR intermediate
was installed, expired Feb 2023. Apple's G3 intermediate
(`https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer`, chains to Apple
Root CA, valid to 2030) had to be added to the login keychain. Verify its subject
matches the certificate's issuer before installing it.

`security find-identity` reporting `0 valid identities found` is the symptom of a
broken chain, not a missing certificate. `security find-certificate -c "Apple
Development"` distinguishes the two.

The Makefile discovers the identity rather than hardcoding it, so the repo — which
is public — carries no email address, and still builds on a machine with no
certificate by falling back to ad-hoc.

First use of the key prompts for keychain access. Choose **Always Allow**; plain
Allow is one-shot and the next build hangs on an invisible dialog.

This identity signs locally only. Distributing to other people needs a Developer
ID certificate and notarisation, which requires the paid program — see the
distribution tiers discussion. Building from source stays free for anyone,
because a locally built app is never quarantined.

---

## D-12: Paste timing, and what could not be measured

Phase 4's synthetic Cmd+V. Three things were settled here.

**`.nonactivatingPanel` really does not steal frontmost — verified, not assumed.**
S-12 depends on it and the assumption was worth checking. A panel built with
ClipFlow's exact configuration (`.nonactivatingPanel`, `.screenSaver` level,
`orderFrontRegardless()` then `makeKey()`), opened 10 times over another app:

```
panel is key window          10/10 yes
our app active               10/10 no
NSWorkspace.frontmostApplication while open   unchanged, 10/10
```

So the panel takes key focus without taking activation. Capturing the frontmost
app before the open is still required, because the status item click path can
leave ClipFlow itself frontmost, and because "verified today" is not "guaranteed
by the API".

**The settle delay is 60 ms, sized against the window server, not a guess.**
HP-2's "brief moment" is the target app waiting for our panel to actually go
away. Timing `close()` to the window leaving `CGWindowListCopyWindowInfo`, over
the same 10 opens:

```
min 2.0 ms    mean 20.1 ms    max 46.8 ms
```

60 ms clears every observation and is under two frames of perceptible lag. Before
this the code waits for the captured app to be frontmost again (polled at 10 ms,
250 ms cap), which in the normal flow costs nothing because frontmost never
changed.

**What was not verified: an actual paste into an actual app.** ClipFlow has no
Accessibility grant yet — `tccd` reports `kTCCServiceAccessibility ... Denied
(System Set)` for `com.jayyy044.clipflow` — so the only code path that can run
today is the copy-only fallback. A separate harness that does have the grant was
built to measure the delay end to end against a scratch TextEdit document, and
its synthetic events were silently discarded (plain typing did not reach TextEdit
either), so it proved nothing about timing. 60 ms is therefore an upper bound on
a measured *proxy*, not a measured success rate.

That is why `pasteSettleMilliseconds` exists in UserDefaults: being early fails
silently — the keystroke is eaten, the panel is already gone, and nothing says
why. Tuning it must not require a rebuild.

**Paste-as-plain-text is currently the same code path as paste.** FR-5.2 says
Option+Shift+Enter strips RTF. Nothing stores RTF: text items have `content` and
no `rtf_data` column, so for a text item the two produce byte-identical
pasteboard contents. The flag is threaded into `Clipboard.copy` anyway so the RTF
representation has exactly one place to be added, and the binding exists so the
behaviour does not have to be discovered later. For image items the flag is
ignored — PNG is written either way.

---

## D-13: Link detection — links only, scanned to 64k, backfilled at launch

Phase 8, FR-5.1. Three things settled here.

**No phone numbers, confirming the v1 cut.** FR-5.1 asks for `.phoneNumber`
alongside `.link`, but FR-5.2's action table defines no phone action, so the
column would be written on every copy and read by nothing. A second detector pass
per copy for a dead column. Reinstate it together with an action, not before.

**The detector input is capped at 64k characters, and the cap is measured.**
S-4 already caps stored content at 1 MB, which is still far too much to run a
regex pass over on the capture path. On deliberately link-dense text — a URL
every ~50 characters, the worst case there is:

```
1.9 M chars    1343 ms
64k chars        21 ms
```

Ordinary text is much faster; 21 ms is the pathological ceiling, not the normal
cost. 64k is also well past any text a link is meaningfully *in* — nobody opens
the 900th URL of a pasted log. A match that runs into the cut-off is discarded,
because half a URL opens the wrong page rather than no page.

**Backfilled on launch, not in the migration.** Detection is `NSDataDetector`,
so it cannot happen in SQL, and without a backfill every pre-existing row would
show no link glyph and the feature would read as broken on the history the user
already has. Same shape as the OCR queue's FR-4.5 resume pass: a detached
`.utility` task at launch over `kind='text' AND detected_urls IS NULL`, ids first
and content fetched one row at a time (rows are up to 1 MB each). `NULL` means
"never scanned" and `[]` means "scanned, no links", which is what makes the pass
converge and stay converged.

**What `.link` actually matches, observed rather than assumed:**

| Input | Detected |
| --- | --- |
| `github.com` in prose | `http://github.com` — bare domains do get a glyph |
| `someone@example.com` | `mailto:someone@example.com` — Cmd+O opens the mail client |
| `/Users/me/x.txt`, `localhost:3000`, `git@github.com:u/r.git` | nothing |
| `[docs](https://example.com/a_b_(c))` | keeps the markdown's trailing `)` |

The email and bare-domain cases are `NSDataDetector`'s own classification and are
left alone: filtering `mailto:` would be deciding for the user that an address is
not a link, and the glyph costs nothing when ignored.

---

## D-14: `pin_slot` allocation — nine slots, lowest free wins, tenth pin refused

The three questions the "known conflicts" section left open, settled together
because they are the same question asked three ways: **is the slot number
meaningful, or incidental?** It is meaningful — D-3 already decided the whole
point of a slot is that it does not move — so every answer below is the one that
keeps the number stable and visible.

**Nine slots, and a tenth pin is refused.** `Option+1..9` is the entire reason
`pin_slot` exists (FR-5.2), so there are exactly nine addressable pins. The
alternative — pin without a slot — creates a second class of pin that survives
eviction but no shortcut reaches, which is a pin that half works and cannot be
told apart from one that fully works. Refusal says so out loud: the panel shows
"All 9 pin slots are in use — unpin one first." Silently doing nothing is
indistinguishable from a broken shortcut, and the pinned section is right there
to unpin from.

**Freed slots are reused, lowest-numbered first.** Holding a slot open for the
row that vacated it means unpinning your slot-1 item leaves `Option+1` dead
until you re-pin something you have no way to nominate. Lowest-first also keeps
the used range dense, so the shortcuts in play are always `Option+1..n` rather
than an arbitrary scatter.

**The pinned section is ordered by slot, not by pin time.** The number on the
row has to be the number you press. Ordering by recency would make position and
shortcut disagree, which is exactly the failure D-3 rejected for the unpinned
list.

Uniqueness is enforced by `CREATE UNIQUE INDEX idx_items_pin_slot ON
items(pin_slot) WHERE pin_slot IS NOT NULL`, not only by the allocator — two
rows sharing a slot would make `Option+N` resolve to an arbitrary one of them.
Allocation reads the used set and claims a slot inside a single write
transaction, so two pins in the same millisecond cannot both see the same gap.

### Retention, which is where this could have gone badly

FR-2.5's "keep the newest N unpinned" is load-bearing on the word *unpinned*.
`WHERE pinned = 0` sits inside the eviction subquery, so pinned rows are out of
the `OFFSET` count as well as out of the `DELETE`. Filtering only the delete
would leave nine pins consuming nine of the hundred slots and silently shorten
the history — deleting unpinned rows early, which is the one outcome the user
never asked for. Verified against 150 filler rows with nine pins deliberately
older than all of them: 192 rows in, 109 out, all nine pins intact with slots
1..9.

---

## D-15: A backup is the database **and** `images.noindex`, and `HOME` does not move it

Images live on disk under `images.noindex`; the database stores only their paths
(FR-2.2). Every "back up before destructive testing" instruction given so far
said to run `sqlite3 ".backup"` on the database and warned that a plain `cp` is
invalid under WAL. None of them mentioned the images directory.

During pinning work a self-test assumed `URL.applicationSupportDirectory`
follows the `HOME` environment variable. It does not — macOS resolves it
independently of that override — so a test written for a scratch copy ran
against the live database. It inserted 162 rows, which pushed the user's real
rows past the retention limit, and eviction did exactly what it is supposed to:
deleted the overflow and their image files with it. The database was restored
from its backup and the 13 rows left orphaned were deleted by hand. The image
files were unrecoverable, because a database backup does not contain them.

Two rules follow. A backup of this app is `.backup` of the database *plus* a
copy of `images.noindex`; either alone restores to a state that does not match
itself. And `URL.applicationSupportDirectory` cannot be redirected with `HOME`,
so anything writing to a "scratch" location has to assert the *resolved* path is
under a scratch directory before it writes, rather than trusting the environment
it was launched with.

---

## D-16: Suspension is a set of reasons, not a flag — and it is not `isPaused`

S-19 implemented. Three sources, six notifications, and the two things that were
easy to get wrong:

**Suspension does not touch `isPaused`.** A user who paused capture and a machine
that went to sleep are different states that happen to have the same effect.
Resuming from sleep starts the timer; `tick` still returns early while the user's
pause stands, so waking never silently un-pauses anyone.

**The reasons are a set, because they overlap and do not nest.** Closing the lid
posts display sleep *and* system sleep; a machine woken by the power button is
awake while still locked. With a single bool the first resume to arrive wins and
the poller runs through the lock screen. Observed exactly that during
verification, and it is what the set fixes:

```
16:15:46  capture suspended (display)     pmset displaysleepnow
          (screenIsLocked arrives, timer already down — recorded, not logged)
16:16:00  capture resumed (lock)          only after BOTH cleared
```

The first tick after resuming sees a `changeCount` that moved while we were down
and captures whatever is on the pasteboard now. Deliberate: the alternative is
losing a copy made between the unlock and the next tick.

Verified by posting `com.apple.screenIsLocked` / `...Unlocked` on
`DistributedNotificationCenter` — the same names and payload the system posts —
and by `pmset displaysleepnow`. A copy made while suspended did not reach the
database until the resume. System sleep (`willSleep` / `didWake`) was **not**
exercised: it registers in the same loop as display sleep, but suspending the
machine also suspends the shell doing the checking.

---

## D-17: An RTF item is one row, not two, and re-copying it does not restyle it

FR-1.2's `rtf_data` landed, which is what makes FR-5.2's Option+Shift+Enter
differ from Enter (D-12 recorded that it did not).

**Dedupe still hashes the plain string only, so the same text with different
formatting is one row.** Two rows whose `preview` is byte-identical cannot be
told apart in the list — which is the exact failure D-5b rejected. Formatting is
invisible until paste, so a second row would look like a duplicate bug and would
be picked between at random.

Corollary, chosen rather than fallen into: a dedupe hit bumps `last_used_at` and
leaves `rtf_data` alone, so the formatting is the one it was **first** captured
with. Rewriting it on every hit would make the same list row paste differently
depending on where you last copied the text from, and nothing on screen would
say so. Observed working: copying the styled string, then the identical plain
string, kept one row with its RTF intact.

**The RTF cap is the same 1 MB as the plain string (S-4), not a larger one.** It
goes into the same row and spends the same 5 MB database budget, and rich text
inflates unpredictably — hex-encoded embedded images most of all. Over the cap
the RTF is dropped and the plain string is still stored, so the item stays
captured and searchable and the only loss is formatting: the app's behaviour
before this change.

Richest representation is written to the pasteboard first, because a reader takes
the first declared type it understands. RTF written after the string would never
be chosen and the two paste actions would collapse back into one.

Still true from the known-conflicts list: no `public.html` is retained. Also not
retained: an RTF-only copy with no `public.utf8-plain-text` alongside is still
dropped, as it was before. Both are rare and neither regressed.

---

## D-18: The OCR helper process, measured — D-9's upgrade path, taken

D-9 left this deferred with "revisit if idle after OCR crosses 60 MB". Taken
early because the fix turned out to be ~60 lines and no IPC framework: a second
executable, one image path in as `argv[1]`, recognised text out on stdout,
launched with `Process`. No XPC — XPC buys a service lifetime, which is the
exact cost being avoided.

Measured on the running app, same machine and method as D-9
(`footprint -p $(pgrep -x ClipFlow)`):

| | in-process (D-9) | helper process |
| --- | --- | --- |
| fresh launch, before any OCR | 24 MB | 26 MB |
| peak during recognition | 113 MB | 30 MB |
| immediately after | 54 MB | 30 MB |
| after 90 s idle | 46 MB | 29 MB |

The 60–64 MB Vision costs is still paid, but in a process that exits: the helper
measured 64 MB max RSS and 0.49 s wall for a 900×260 PNG, and the app never sees
it. Idle after OCR is back to roughly where it was before OCR existed.

**Settings are D-8's, moved verbatim** — `RecognizeTextRequest`, `.accurate`,
`usesLanguageCorrection = false`, English pinned, no auto-detection. The helper
is a relocation, not a re-tune.

**A missing helper leaves rows `pending`; everything else fails them.** FR-4.3
forbids retries, so marking every queued screenshot `failed` because a build
shipped without the binary would destroy work a corrected build could still do.
The drain stands down instead and FR-4.5 picks the rows up next launch. A crash,
a non-zero exit and the 30 s deadline are all terminal for the one row, which is
what FR-4.3 asks for. All four paths were exercised:

```
helper deleted        item left pending, drain stood down, done on next launch
helper exits 3        failed
helper hangs          terminated at 30 s, failed (exit 15)
helper works          done, text correct
```

The 30 s deadline is not FR-4.6's latency target — it is sized to never fire in
normal use (D-8 measured 0.22–0.40 s) and only exists so a wedged helper cannot
hang the queue forever.

The app locates the helper beside its own executable
(`Bundle.main.executableURL`), so the bundle at `Contents/MacOS/ClipFlowOCR` and
`make debug`'s `.build/debug/ClipFlowOCR` both resolve with no build-time
knowledge of either. The Makefile signs the nested binary **before** the bundle,
with the same discovered identity — signing the app first and the helper second
invalidates the app's own signature.

---

## D-19: Settings is a hand-built `NSWindow`, and the status menu keeps the bulk actions

D-2 chose `NSStatusItem` + `NSPanel` over `MenuBarExtra`, which means `main.swift`
drives `NSApplication` directly and there is no SwiftUI `App` type in the
project. A `Settings {}` scene therefore has nowhere to be declared and
`SettingsLink` has no scene to point at — checked before writing anything, not
assumed. The window is an `NSWindow` holding an `NSHostingView`, created once and
reopened.

Two consequences of `.accessory` that a normal app never hits:

- The app has to be activated (`NSApp.activate`) before the window can take key
  focus, and without key focus `KeyboardShortcuts.Recorder` cannot record —
  clicking a recorder in an inactive window does nothing at all.
- The app stays *active* after the window closes, with no windows left. The next
  copy would then be attributed to ClipFlow rather than to the app the user is
  typing in, because `source_bundle_id` is `NSWorkspace.frontmostApplication`.
  `NSApp.hide(nil)` in `windowWillClose` hands frontmost back.

**Bulk actions stayed in the status menu.** FR-7.5's two clears, and "Unpin All",
are one-shot commands, not preferences — they have no state to display and
nothing to remember. Putting them in Settings would mean opening a window to run
a command and then closing it again, and would leave the menu's existing
`Clear History…` behaviour split across two surfaces. Settings holds only what
persists: launch at login, pause, shortcuts, the exclusion list.

**The exclusion list is UserDefaults, not a table.** It is read on the copy path,
on every capture, and the whole payload is a handful of bundle ids — a SQLite
round trip per copy buys nothing. Bundle ids rather than names, because a name is
localized and survives no rename, and the bundle id is what `PasteboardMonitor`
already holds. FR-7.2's "managed by picking apps" is `NSOpenPanel` filtered to
`.application`; an app with no bundle identifier is refused rather than stored,
since it could never match a captured `source_bundle_id`.

---

## D-20: Pause persists, ignore-next-copy does not, and the icon is what makes that honest

FR-7.4 and FR-7.3 look like the same switch and are not.

**Pause is stored in UserDefaults and survives quitting.** Someone who paused
capture did it for a reason that outlives one run of the app, and a pause that
quietly lapses on the next launch resumes recording exactly when they thought it
was off — the one outcome they were avoiding. This is only defensible because
FR-7.4's other half exists: the menu bar icon is drawn with `appearsDisabled`
while paused, so the state is visible without opening anything. Without the
dimmed icon a persisted pause would be a hidden setting, and the app would look
broken instead of paused.

`appearsDisabled`, not `isEnabled`: the latter also stops the button responding
to clicks, which would strand the user with no way back to the menu that
un-pauses it.

**Ignore-next-copy is not persisted.** "The next copy" means the next one;
carrying it across a relaunch would silently eat a copy hours later. It is a
toggle rather than a one-way arm, so an accidental Option-click is undone by
another Option-click, and it shows as a filled glyph plus a tooltip because the
menu-bar affordance FR-7.3 asks for is otherwise invisible. Option, not Command
or Control: Command-drag is how macOS rearranges the menu bar, and Control-click
is a right-click, which is already the menu.

**It is spent in `tick()`, not in `capture()`.** Our own paste writes are
filtered out immediately above by `ignoredChangeCount`, so arming it can never be
consumed by the app's own pasteboard traffic — and spending it there suppresses
the copy whatever it turns out to hold, including the sizes and types `capture()`
would have dropped on its own.

`isPaused` reads UserDefaults through rather than mirroring it into a stored
property, so the poller and the Settings checkbox cannot disagree; it costs a
cached CFPreferences lookup twice a second. Pause is still not a member of
`suspendedBy` — D-16 stands.

**Launch at login is now registered once, not on every launch.** FR-7.7 makes it
a toggle, and the old unconditional `register()` at startup would undo the user's
choice on the next restart — precisely the restart the setting exists to control.
A `didRegisterLaunchAtLogin` flag records that the offer was made; after that the
toggle owns the state. The toggle reads `SMAppService.Status` rather than a
boolean, because macOS commonly parks a successful `register()` at
`.requiresApproval` and a plain checkbox would read "on" for an app that will not
come back after a reboot.

Verified against the live database with markers, live counts unchanged (24 rows,
9 pinned) afterwards:

```
A  no exclusion, capture on    row inserted, source com.googlecode.iterm2
B  frontmost app excluded      NO ROW   "skipped copy from excluded app com.googlecode.iterm2"
C  exclusion removed           row inserted
D  capture paused              NO ROW
E  unpaused                    row inserted
```

The clears and unpin-all were exercised as SQL against a scratch copy, never the
live database (D-15): clear-unpinned left 9 rows with slots 1..9 intact and kept
a pinned image's `image_path` in the set handed to `sweepOrphans`; unpin-all left
24 rows with every slot NULL and reported 0 changes on a second run.

---

## D-21: The NFR budgets, measured

PRD §6 calls these acceptance thresholds rather than aspirations. Every number
below was measured on the signed release build installed in `/Applications`, on
Apple Silicon. Method is stated for each because "measured" without a method is
just a nicer-sounding assertion.

| Metric | Budget | Measured | |
| --- | --- | --- | --- |
| Idle resident memory | < 60 MB | **26 MB** | pass |
| Idle CPU | < 0.1% | **0.033%** | pass |
| Cold launch to menu bar ready | < 500 ms | **86–112 ms** | pass |
| Search latency, 10k items | < 50 ms | **6 ms median, 36 ms worst** | pass |
| OCR per screenshot | < 1.5 s | **321–366 ms** | pass |
| Database size, 1000 text items | < 5 MB | **0.83 MB** | pass |
| Hotkey to window visible | < 100 ms | **15 ms median, 35 ms first** | pass |

**Memory** is `phys_footprint`, per D-6 — RSS is the wrong yardstick and the
reasoning is recorded there rather than re-argued here. `footprint -p $(pgrep -x
ClipFlow)`.

**CPU** by differencing the process's consumed CPU time across a 90 s idle
window rather than sampling `top`: 0.03 s of CPU over 90 s of wall clock. An
instantaneous sample of a process that wakes twice a second mostly catches it
asleep and flatters the number.

**Cold launch** from `Timing.processStart`, which reads the exec timestamp out of
the kernel's process table via `sysctl`, to the moment the status item is
clickable. Timing from the first line of `main` would miss dyld, the Swift
runtime, AppKit and SwiftUI — that is, most of a cold launch. Reported at the
status item rather than at the end of `applicationDidFinishLaunching`, because
the database, OCR queue and URL backfill all run after it and none of them gate
the user.

**Search** against a 10,000-row scratch database built from production's own
schema, so the FTS5 configuration, indexes and triggers are identical. The exact
production query — `MATCH`, `snippet()`, `bm25()` weighting, pinned-first
ordering, `LIMIT 500` — run 25 times across six shapes: very common prefix,
common word, two prefixes, a single rare row, three terms, and no matches. Worst
single run of the whole set was 36 ms, on the query returning 500 rows from the
most common prefix.

Worth stating: retention keeps 100 items (S-18b), so the app cannot actually
hold 10k. The measurement is a deliberate stress test well beyond real use, not
a description of it.

**OCR** timing the helper executable exactly as `OCRQueue` invokes it, process
spawn included, on a real 3024×1964 screenshot. The spawn is the price of D-9's
memory fix and it is in the number.

**Database size** measured, then divided: 10,000 text rows including the FTS
index occupy 8.5 MB, so 1,000 occupy 0.83 MB. Excludes images, which live on
disk by design (FR-2.2).

**Hotkey to window visible** over 15 real keypresses: 7.7–17.5 ms, median 15 ms,
except the very first open of a launch at 35 ms — SwiftUI builds the view tree
once and that cost lands on whichever open comes first. Measured from the top of
`Panel.open` to after `makeKey()`, which is when the window is on screen and
accepting keys rather than when the handler returns.

The same run shows why the first list load reads 70 ms and every later one 0.5
ms: the first one pays for opening the database and running migrations. Neither
is on the path the hotkey budget covers.

**NFR-1** holds — Swift and SwiftUI throughout, no webview. **NFR-3** holds — the
dependency graph is exactly `grdb.swift` and `keyboardshortcuts`.

**NFR-2 was failing and is now fixed.** `lipo -archs` on the shipped binary
reported `arm64` alone: SPM builds for the host architecture unless told
otherwise, and nothing ever told it. Every "universal binary" claim up to this
point was untrue and nobody had checked. `make bundle` now passes `--arch arm64
--arch x86_64`, which also moves the output to `.build/apple/Products/Release`.
Both the app and the OCR helper are now `x86_64 arm64`, the bundle still
verifies `--deep --strict`, and idle footprint is unchanged at 26 MB.

Worth noting as method rather than result: this is the only budget that failed,
and it failed silently for the entire build. Nothing surfaces it except running
the check — which is the argument for §6 being acceptance criteria that get
measured rather than intentions that get asserted.

---

## D-22: Enter and click paste, and there is no copy-without-paste key at all

FR-5.2 as written put copy on the unmodified Return and click, and paste behind
`Option+Enter`. That is now inverted, and the copy-only chord is gone entirely:

| Key | Before | After |
| --- | --- | --- |
| `Enter` / click | Copy and close | **Paste** |
| `Shift+Enter` | — | **Paste as plain text** |
| `Option+Enter` | Paste | pastes, like any other Return |
| `Option+Shift+Enter` | Paste as plain text | retired, folded into `Shift+Enter` |

**Why paste became the default.** The user expected clicking a row to paste, and
said so unprompted twice. Two independent surprises at the same spot is a spec
problem, not a user problem. The reasoning holds on its own: you open the panel to
*use* an item, so pasting is the common case and copy-without-paste is the rare
one. Putting a modifier on the common case is friction on exactly the path G2's
three-second budget covers, and it is what Maccy does — which is where the
instinct came from.

**Why no copy-only key survives.** The first cut of this decision moved copy-only
onto `Option+Enter`. It did not survive the obvious question — what is it *for*?
Every case where pasting cannot happen already falls back to copy without being
asked, because `HistoryView.paste` calls `Clipboard.copy` before `Paster.paste`
checks `AXIsProcessTrusted` or `IsSecureEventInputEnabled`. No grant, or secure
input held: the item is on the clipboard and the user is told why. That covers the
failure modes. What a deliberate chord adds is only "put it somewhere I am not
right now" — real, but rare, and already served by the context menu's **Copy**,
which is where a mouse user would look. A third thing Return can do is a worse
price than a right-click on the rare path.

Noted for the record: `Cmd+Enter` was considered and rejected before the binding
was dropped altogether. A Command chord is a *key equivalent* — offered to the
responder chain and the menu system, never arriving at SwiftUI's `onKeyPress`,
the trap already documented for `Cmd+O`. It would have needed its own case in
`Panel.performKeyEquivalent` plus a notification hop. If copy-only ever earns a
key again, that plumbing is the cost.

**The permission fallback needed no code.** FR-5.4 already treats copy-only as a
legitimate outcome, and the ordering in `HistoryView.paste` already delivers it:
`Clipboard.copy` writes the pasteboard *before* `Paster.paste` checks
`AXIsProcessTrusted`. Without the grant the item is on the clipboard and the user
gets the one-time explanation — the same behaviour as before, now reached by the
default key rather than a modified one.

**One honest regression.** `explainSecureInput` is deliberately not persisted, on
the old reasoning that secure input "only ever surfaces on an explicit
Option+Enter, so it can't nag". That is no longer true: with a password field
focused, a plain Return now raises it. Kept anyway, un-suppressed — a user pasting
into a password field is precisely who needs to be told the keystroke was
discarded. Revisit if it proves annoying in practice rather than in theory.

**Still unverified.** `Shift+Enter` differing from `Enter` depends on the RTF
paste path, which no human has exercised end to end. See the RTF paste thread —
capture is proven (441 bytes stored from a real RTF write), the two *modes* are
not.

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
- **S-18b. Retention N = 100, not FR-2.5's 1000.** Chosen by the user; kept as one
  constant (`ItemRepository.retentionLimit`) rather than a setting, because
  Phase 9 owns settings. Landed at 100 after 20 was flagged as too low for an app
  whose G3 is finding a screenshot from last week — 20 is roughly a morning of
  copying, which would leave the OCR search that justifies the whole build with
  almost nothing to search. 100 costs nothing measurable: FR-2.5's own budget is
  5 MB for 1000 text items, and the list is never scrolled that far because
  retrieval goes through search. Eviction converges on the next launch, so
  changing it again cleans up retroactively.

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
Resolved since: `pin_slot` allocation rules, see D-14. `Clear History…` taking
pinned items with it — split into `Clear Unpinned History…` and
`Clear All History…`, see D-19/D-20.
