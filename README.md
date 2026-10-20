<div align="center">
  <h1>Textolimiti</h1>
  <p>Progress counted over the real text only.</p>
  <p>by <a href="https://sypian.ski/">Jakub Sypiański</a> · License: AGPL-3.0</p>
  <p>Updated 24 July 2026</p>

  [![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-KOReader-brightgreen)
</div>

> **Part of the KOReader family.** Related apps:
> [Rosetta](https://github.com/sypianski/rosetta.koplugin), a translation under the book text;
> [Hairline](https://github.com/sypianski/hairline.koplugin), a thin progress bar at the bottom edge;
> [KoTheme](https://github.com/sypianski/kotheme.koplugin), rounded corners and thinner borders;
> and others.

A [KOReader](https://github.com/koreader/koreader) plugin that fixes the reading-progress percentage so it tracks the **real text** of a book — not its front matter, endnotes, or bibliography.

> *Textolimiti* — Ido for "text limits", from *texto* + *limiti*.

A 300-page novel with a 40-page introduction and 30 pages of endnotes is really 230 pages of story. KOReader's default progress bar counts every page equally, so when the prose ends at the 77 % mark, the bar still says "23 % left to read". This plugin lets you mark *where the actual text begins and ends*, and the percentage updates accordingly — without throwing away the front matter or back matter (you can still navigate to them).

## Install

Clone the repository (it is the plugin directory) into KOReader's `plugins/` folder under the name `textolimiti.koplugin`:

```sh
git clone https://github.com/sypianski/textolimiti.koplugin \
    ~/.config/koreader/plugins/textolimiti.koplugin
```

The path above is for native Linux. On other systems use the plugins folder of your KOReader:

| Platform | Plugins folder |
|---|---|
| Linux (native) | `~/.config/koreader/plugins/` |
| Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
| Kobo / Kindle / PocketBook | `koreader/plugins/` on the device |
| Android | `koreader/plugins/` in KOReader's storage folder |

Instead of cloning you can download the repository as a ZIP from GitHub and unpack it into the plugins folder; the folder must be named `textolimiti.koplugin`.

Restart KOReader. The plugin registers itself under *Tools > Textolimiti*.

There are no prebuilt releases; the repository is the distribution.

## What it does

Press **N** while reading. A dialog appears:

- **La teksto komenciĝas ĉi tie** — mark the current position as the start of the real text. Anything before becomes front matter (excluded from progress).
- **La teksto finiĝas ĉi tie** — mark the current position as the end. Anything after becomes endnotes / bibliography / index (also excluded).
- **Montri · forigi markojn** — list current marks; tap one to delete.

The dialog labels are in Esperanto.

Marks are stored per book in the `.sdr` sidecar as KOReader [custom hidden flows](https://github.com/koreader/koreader/pull/10982), so they survive font/margin changes, reflows, and KOReader restarts.

You can also set boundaries from the **Table of Contents**: focus a row and press `;` to mark it as the first body chapter, or `:` to mark it as the last body chapter — or long-press a TOC entry to pick either action from a dialog. The TOC then draws a thick black boundary line under the marked entry (one line below the last front-matter chapter, one line below the last body chapter), dividing the list into front matter / body / back matter at a glance. While only one boundary is set, a small triangle (▼ for start, ▲ for end) marks which one it is; once both are set, the three-block layout speaks for itself and the triangle is dropped.

## Technical notes

### How it works

This plugin is a keyboard-driven wrapper around KOReader's built-in [`ReaderHandMade`](https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerhandmade.lua) flows (introduced upstream in [PR #10982](https://github.com/koreader/koreader/pull/10982)).

The "Komenco / Fino" actions edit only the **leading** and **trailing** hidden zones, so interior hidden zones you may have created elsewhere (via the Page-browser UI) are preserved. The plugin owns no separate progress math — it edits `handmade.flow_points` and calls `setupFlows()` to recompute, inheriting xpointer survival under reflow and footer updates from upstream.

### Compatibility

Tested with KOReader 2026.03 on desktop Linux. Requires a build with `ReaderHandMade` (any version after PR #10982 merged).

## How this was made

Textolimiti was written largely by Claude, working from my specifications and
under my direction ("vibe coding"). I reviewed and tested the results, but
the code has not had an independent audit. Treat it as you would any young
project and report what you find.

## Feedback

Textolimiti is a young project. If something breaks, behaves oddly or is missing, tell me:

<!-- feedback-form: https://sypian.ski/uwagi/?app=textolimiti -->
- [Open an issue on GitHub](https://github.com/sypianski/textolimiti.koplugin/issues/new). Bug reports, ideas and questions are all fine there; include your KOReader version, your device and the book format.
- Or email jakub.sypianski@gmail.com.

## Support

Textolimiti is free. If it is useful to you, you can [buy me a coffee on Ko-fi](https://ko-fi.com/sypianski).

## License and credits

Textolimiti is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0), see [LICENSE](LICENSE).

Textolimiti matches KOReader's license. It builds on KOReader's custom hidden flows (`ReaderHandMade`, upstream pull request 10982).

---

<p align="center">Textolimiti · <a href="https://sypian.ski/">Jakub Sypiański</a> · AGPL-3.0</p>
