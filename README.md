# ClipFlow

A native macOS clipboard manager where text you copied and text *inside*
screenshots you copied land in the same search index. Type `connection refused`
and you get both the error message you copied and the screenshot of it.

There is no separate image-search mode, and no toggle. Screenshots are OCR'd on
device with Apple's Vision framework as they arrive, and the extracted text goes
into the same FTS5 index as everything else. Maccy, the closest comparable app,
has no OCR at all.

Menu bar only. Swift and SwiftUI, GRDB/SQLite, two dependencies total, no network
calls of any kind.

## Install

Requires macOS 15 or later. Building needs Xcode or the Command Line Tools — the
build only calls `swift build` and `codesign`, so Command Line Tools is likely
enough, though that has not been tested here.

```
git clone https://github.com/jayyy044/clipflow.git
cd clipflow
make install
```

That builds a universal release binary, assembles `ClipFlow.app`, signs it,
copies it to `/Applications` and launches it. `make uninstall` removes it.

An app you build yourself is never quarantined, so Gatekeeper never gets
involved — no "unidentified developer" dialog, no right-click-Open dance, no
notarisation. That is the whole distribution story: there is no signed release
download, and none is needed.

The Makefile signs with an Apple Development certificate if it finds one and
falls back to ad-hoc if not. Ad-hoc works, with one consequence: macOS keys the
Accessibility grant on the signing identity, so an ad-hoc build loses the grant
on every rebuild and you re-approve pasting each time. See DECISIONS D-11.

## Usage

`Ctrl+Cmd+V` opens the panel — rebindable in Settings. Clicking the menu bar icon
does the same.

The search field is focused on open, so just type. The panel does not steal focus
from the app you were in, which is what makes pasting back into it work.

| Key | Action |
| --- | --- |
| `Enter` | Paste into the app you were in. With nothing selected, takes the top result. |
| Click a row | Same as Enter |
| `Shift+Enter` | Paste as plain text, stripping formatting |
| `Option+P` | Pin or unpin, assigning a stable slot |
| `Ctrl+Cmd+1…9` | Paste a pinned item without opening the panel |
| `Cmd+O` | Open the first detected URL in the default browser |
| `Option+Delete` | Delete the selected item |
| `Up` / `Down` | Move through the list |
| `Esc` | Close |

Right-clicking a row offers the same actions as a menu. Right-clicking the menu
bar icon gives Pause Capture, Ignore Next Copy, Unpin All, Clear History, and
Settings.

Pinned items sit in their own section above the history and are never evicted by
retention. Their slot numbers are stable, so `Ctrl+Cmd+3` always pastes the same
thing — unlike a positional shortcut, which would shift every time you copied
anything.

Pasting presses Cmd+V in the other app for you, which macOS only permits with
Accessibility permission. Without it ClipFlow copies instead and says so once,
leaving "Enable Pasting…" in the menu. Pasting is also skipped while macOS secure
input is active — typically a focused password field — because the synthetic
keystroke would be silently discarded. In both cases the item is on your
clipboard and Cmd+V yourself works.

## Settings

Right-click the menu bar icon → Settings.

- **General** — launch at login, pause capture
- **Shortcuts** — rebind the hotkey and all nine pin slots
- **Excluded Apps** — nothing copied while one of these is frontmost is recorded

## Privacy

No network calls. Not telemetry, not update checks, not an OCR API — the app
makes no outbound connections of any kind. OCR runs on device through Vision.

Everything lives under `~/Library/Application Support/ClipFlow/`:
`clipflow.sqlite` for items and the search index, `images.noindex/` for image
payloads and thumbnails. The `.noindex` suffix keeps Spotlight from indexing your
clipboard screenshots into system-wide search. Nothing is encrypted beyond
whatever FileVault gives you.

Passwords copied from a password manager are never recorded — 1Password,
Bitwarden, Apple Passwords and Chrome all mark them, and marked content is
skipped. API tokens are dropped by shape too: GitHub, GitLab, AWS, Google, Slack,
Stripe, npm, OpenAI/Anthropic keys and PEM private key blocks.

What still gets stored: a password you selected by hand rather than using the
manager's copy button, and anything without a recognisable shape — a plain
password out of `pass` or `gpg`. Exclude the app if that matters to you.

## Performance

Budgets came from the spec; the numbers are measured on the signed release build,
at 10,000 rows where scale applies.

| | Budget | Measured |
| --- | --- | --- |
| Idle memory | < 60 MB | 26 MB |
| Idle CPU | < 0.1% | 0.033% |
| Cold launch | < 500 ms | 86–112 ms |
| Hotkey to window | < 100 ms | 15 ms |
| Search, 10k items | < 50 ms | 6 ms |
| OCR per screenshot | < 1.5 s | 321–366 ms |

OCR runs in a short-lived helper process rather than in-app, because Vision's
model stays resident for the life of whatever process loads it — in-process
recognition peaked at 113 MB. Spawning a process that exits brought the peak to
32 MB. See DECISIONS D-9.

## Limitations

- **Dense tables and charts OCR badly.** Vision returns a fraction of the visible
  text on a dense table, and chart axis labels come back as noise. Terminals,
  code, prose and documentation read fine. Measured, not guessed — DECISIONS D-10.
- **History keeps the newest 100 unpinned items.** Older ones are evicted
  permanently. Delete and Clear History are permanent too — no undo, no trash.
  Pinned items are never evicted. The limit is a constant in source.
- **No sync.** Single machine, by design.
- **No file items.** Copying files in Finder is not captured; text and images only.
- **HTML representations are dropped**, so pasting a web selection into Notion or
  Slack will not match a direct paste.
- **Skipped on capture:** text over 1 MB, images over 32 MB, and images over
  8000 px on an edge are not OCR'd. A failed OCR is never retried.
- **English only** for OCR — the recognition language is pinned, because automatic
  detection is a coin flip on a terminal screenshot.

## Building

```
make bundle      # build dist.noindex/ClipFlow.app
make run         # build and run from dist.noindex/
make debug       # unbundled binary, host arch only, for iterating
make clean
```

`make debug` reads a different UserDefaults domain than the bundle, so the hotkey
preference does not carry across.

## Notes on the build

[DECISIONS.md](DECISIONS.md) records every place the implementation deliberately
diverges from its spec, and why — measurements, failure modes, rejected
alternatives, and the things that turned out wrong.

A few examples of what is in there: the spec recommended forking Maccy, which was
abandoned after reading Maccy's source and finding FTS5 unreachable through its
storage layer (D-1). The spec asked for `usesLanguageCorrection = true`; testing
found it corrupts identifiers, then a larger corpus reversed that result, and the
final call rests on an argument rather than the win count (D-8). A macOS 26 API
that should have been better at tables was rejected after being measured on tables
(D-8). The universal binary was silently arm64-only for the entire project until
someone ran `lipo` (D-21).

It exists so those choices are not silently re-litigated. If something looks
wrong, check there first — it is probably wrong on purpose.

## License

MIT. See [LICENSE](LICENSE).

Portions adapted from [Maccy](https://github.com/p0deje/Maccy) — see
[NOTICE](NOTICE) for third-party attribution.
