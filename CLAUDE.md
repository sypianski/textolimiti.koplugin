# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file [KOReader](https://github.com/koreader/koreader) plugin (`textolimiti`) that
corrects the reading-progress percentage so it tracks only the **real body text** of a book,
excluding front matter, endnotes and bibliography — without deleting those sections (they stay
navigable). The whole plugin is `main.lua` + `_meta.lua`; there is no build system, no
dependencies to install, and no test harness. UI-facing strings are in **Esperanto** (the
project name *Textolimiti* is Ido).

## Deploying / running

There is no build step. To run, the repo directory must be present inside KOReader's `plugins/`
folder as `textolimiti.koplugin/` (KOReader discovers plugins by the `.koplugin` suffix and loads
`_meta.lua` then `main.lua`). Typical dev loop:

```bash
# symlink the working tree into a KOReader install, then restart KOReader
ln -s "$PWD" ~/.config/koreader/plugins/textolimiti.koplugin
```

"Testing" = launching KOReader, opening a book, and exercising the plugin (key **N** opens the
main dialog; the plugin surfaces under *Tools → Textolimiti*). There is no way to unit-test in
isolation because every code path calls into live KOReader modules (`ReaderHandMade`, `ReaderToc`,
`ReaderView`, `UIManager`). Runtime diagnostics go through `logger.info` — read them via KOReader's
`crash.log` or console output.

## Architecture — the one thing to understand

**The plugin owns no progress math.** All percentage/page-count logic lives in KOReader's built-in
`ReaderHandMade` module (`frontend/apps/reader/modules/readerhandmade.lua`, upstream PR #10982),
which implements "custom hidden flows". This plugin is a **keyboard-driven wrapper** that:

1. Mutates `handmade.flow_points` — a page-sorted list of `{page, hidden, xpointer}` items. A
   *leading hidden zone* (front matter) is a `hidden=true` point at page 1 followed by an optional
   non-hidden "restart" point; a *trailing hidden zone* (endnotes) is a `hidden=true` point with no
   restart after it. Interior hidden zones created by KOReader's own Page-browser UI are deliberately
   left untouched — see `_findLeadingZone` / `_findTrailingZone`, which classify only the leading and
   trailing runs.
2. Calls `handmade:setupFlows(true)` (silent) to recompute, then hand-refreshes footer + TOC
   (`_refresh`). Silent mode avoids the `UpdateToc` broadcast that would close an open TOC menu.
3. Persistence is automatic: `flow_points` is saved to the book's `.sdr` sidecar under
   `handmade_flow_points`, so marks survive reflow/font changes and travel with the book.

Because marks are anchored to **xpointers** (stable DOM anchors from the TOC chapter headings)
rather than raw page numbers, they survive re-rendering. Page numbers are recomputed from xpointers
on demand (`getPageFromXPointer`) and kept fresh by ReaderHandMade's `updateHandmagePages`.

### Deliberate deviations from ReaderHandMade defaults

- **Soft boundaries** (`_softenBoundaries`): ReaderHandMade normally makes page-turns *skip* hidden
  pages. That traps the reader on the last body page, unable to reach the bibliography. This plugin
  restores plain `Document.getNextPage/getPrevPage` so every page stays reachable, while the
  percentage math still ignores hidden flows. This must be re-applied after **every** `setupFlows`
  call, hence the `_installSetupFlowsHook` monkey-patch.

### Integration points (all via monkey-patching live KOReader widgets)

The plugin hooks several KOReader objects at runtime because there are no upstream extension points:

- **Key events** (`init`): `N` opens the dialog; `;` / `:` mark the focused TOC row as body-start /
  last-body-chapter. Registered into `self.ui.active_widgets` so keys reach the plugin even when
  menus are on top. `input_is_active()` guards against stealing keys while a text field has focus.
- **View module** (`onReaderReady` → `registerViewModule`): `paintTo` draws corner manicule glyphs
  (☞ start page, ☜ end page) and, when the current page is inside a hidden zone, masks the footer
  strip (its percentage is meaningless outside the body).
- **TOC hooks** (`_installTocHook` and friends): wrap `onShowToc`, `updateItems`, `onMenuHold`, and
  `paintTo` on the live `toc_menu` so the plugin can (a) thicken the bottom-rule under the two
  boundary TOC rows to visually split intro · body · back-matter, and (b) paint ▼/▲ boundary
  triangles in a second paint pass (needed so the ▼ can sit *below* a row's line without the next
  row overpainting it). Each hook is idempotent, guarded by a `_ido_*_hooked` flag, because the
  widgets are rebuilt on every render.

## Coordination with the plugin family

textolimiti does **not** take part in `pluginaro` and has no overlay of its own, so there is nothing to
register or provide. Sibling repos: `keyreader` (with `visel`), `kopad` (gamepad), `marjenoti`, `kotheme`,
`frontespico`; each is its own GitHub repo with the same rules in its own `CLAUDE.md`.

- **Do not add `GamepadButtonDown` / `GamepadAxisMotion` handlers here.** kopad is the only plugin that
  consumes the pad globally; a second consumer would act on the same press. The TOC menu and the main
  dialog count as ordinary windows for kopad (stock keys). If a pad control is really needed, add an
  optional public method here and let kopad call it through `pluginaro` — the pad-side rules and a
  checklist are in kopad's `CLAUDE.md`.
- Keep the `_ido_*` / `_tl_*` field prefixes: they keep the monkey-patches here clear of fields the other
  family plugins set on the same KOReader objects.
- Working copies: develop in `~/utensili/koreader/textolimiti`;
  `~/modi/koreader/koplugins/textolimiti.koplugin` is a submodule checkout of the same repo used for
  deployment — pull there after pushing, do not commit there.

## Conventions

- Private methods/fields are `_camelCase` / `_snake_case` with a leading underscore; internal state
  flags use the `_ido_` / `_tl_` prefixes (`ido` from the language, `tl` from *textolimiti*) to avoid
  colliding with KOReader's own fields on the objects being monkey-patched.
- Every hook checks-and-sets a guard flag before patching so repeated `onShowToc` / `onReaderReady`
  calls don't stack wrappers.
- The extensive block comments above each function explain *why* a workaround exists (which KOReader
  behavior forced it) — preserve that reasoning when editing; it is the main defense against
  re-introducing bugs when KOReader internals shift.
- Requires a KOReader build with `ReaderHandMade` (anything after PR #10982). When it's absent,
  every entry point degrades gracefully via `_warnNoHandmade` / early returns on `self.ui.handmade`.
