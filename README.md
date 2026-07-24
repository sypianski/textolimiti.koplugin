# textolimiti.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin that fixes the reading-progress percentage so it tracks the **real text** of a book — not its front matter, endnotes, or bibliography.

> *Textolimiti* — Ido for "text limits", from *texto* + *limiti*.

## Why

A 300-page novel with a 40-page introduction and 30 pages of endnotes is really 230 pages of story. KOReader's default progress bar counts every page equally, so when the prose ends at the 77 % mark, the bar still says "23 % left to read". This plugin lets you mark *where the actual text begins and ends*, and the percentage updates accordingly — without throwing away the front matter or back matter (you can still navigate to them).

## Install

Drop `textolimiti.koplugin/` into KOReader's `plugins/` directory:

| Platform | Path |
|---|---|
| Linux (native) | `~/.config/koreader/plugins/` |
| Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
| Kobo / Kindle / PocketBook | `koreader/plugins/` on the device |
| Android | `koreader/plugins/` in KOReader's storage folder |

Restart KOReader. The plugin registers itself under *Tools → Textolimiti*.

## Use

Press **N** while reading. A dialog appears:

- **La teksto komenciĝas ĉi tie** — mark the current position as the start of the real text. Anything before becomes front matter (excluded from progress).
- **La teksto finiĝas ĉi tie** — mark the current position as the end. Anything after becomes endnotes / bibliography / index (also excluded).
- **Montri · forigi markojn** — list current marks; tap one to delete.

Marks are stored per book in the `.sdr` sidecar as KOReader [custom hidden flows](https://github.com/koreader/koreader/pull/10982), so they survive font/margin changes, reflows, and KOReader restarts.

You can also set boundaries from the **Table of Contents**: focus a row and press `;` to mark it as the first body chapter, or `:` to mark it as the last body chapter — or long-press a TOC entry to pick either action from a dialog. The TOC then draws a thick black boundary line under the marked entry (one line below the last front-matter chapter, one line below the last body chapter), dividing the list into front matter / body / back matter at a glance. While only one boundary is set, a small triangle (▼ for start, ▲ for end) marks which one it is; once both are set, the three-block layout speaks for itself and the triangle is dropped.

## How it works

This plugin is a keyboard-driven wrapper around KOReader's built-in [`ReaderHandMade`](https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerhandmade.lua) flows (introduced upstream in [PR #10982](https://github.com/koreader/koreader/pull/10982)).

The "Komenco / Fino" actions edit only the **leading** and **trailing** hidden zones, so interior hidden zones you may have created elsewhere (via the Page-browser UI) are preserved. The plugin owns no separate progress math — it edits `handmade.flow_points` and calls `setupFlows()` to recompute, inheriting xpointer survival under reflow and footer updates from upstream.

## Compatibility

Tested with KOReader 2026.03 on desktop Linux. Requires a build with `ReaderHandMade` (any version after PR #10982 merged).

## License

[AGPL-3.0](LICENSE). KOReader itself is AGPL-3.0; this plugin matches.
