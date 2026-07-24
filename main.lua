--[[
Textolimiti — KOReader plugin.

Lets the reader mark, by keyboard, where the real text of a book starts
and ends, so the progress percentage stops counting front matter, TOC,
endnotes and bibliography pages.

Nothing about progress is reimplemented: this is a thin wrapper around
KOReader's built-in custom-hidden-flows machinery (ReaderHandMade in
frontend/apps/reader/modules/readerhandmade.lua, upstream PR #10982).
The plugin only edits `handmade.flow_points` and asks ReaderHandMade to
recompute. Persistence lives in the .sdr sidecar under
`handmade_flow_points`, so marks survive close/reopen and travel with
Syncthing alongside annotations.

Default key: N.
]]

local Blitbuffer     = require("ffi/blitbuffer")
local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local Device         = require("device")
local Document       = require("document/document")
local Event          = require("ui/event")
local Font           = require("ui/font")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu           = require("ui/widget/menu")
local Notification   = require("ui/widget/notification")
local Size           = require("ui/size")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")
local _              = require("gettext")
local T              = require("ffi/util").template
local Screen         = Device.screen

-- Manicule glyphs marking the body-text boundaries on the reader page.
-- Same font/size as keyreader/menupage's focus indicator — proven to
-- render with the bundled NotoSans + freefont fallback chain.
local MANICULE_FONT_SIZE = 28
local START_GLYPH      = "\u{261E}"  -- ☞ white right pointing index
local END_GLYPH        = "\u{261C}"  -- ☜ white left pointing index

-- Small triangle glyphs drawn in the centre of the boundary lines in
-- the TOC. ▼ on the start line (body starts BELOW), ▲ on the end line
-- (body ends ABOVE).
local TRIANGLE_FONT_SIZE = 14
local START_TRIANGLE     = "\u{25BC}"  -- ▼ black down-pointing triangle
local END_TRIANGLE       = "\u{25B2}"  -- ▲ black up-pointing triangle

-- (Earlier versions of this plugin appended "[komenco]" / "[fino]"
-- labels to the TOC entries' post_text. We now draw a thick black
-- bottom line under the last front-matter entry and under the last
-- body entry, which divides the TOC into three visual blocks —
-- front matter, body, back matter — without consuming horizontal
-- space inside the chapter title.)

local Textolimiti = InputContainer:extend{
    name         = "textolimiti",
    is_doc_only  = true,
}

------------------------------------------------------------------
-- Focused-input guard
--
-- Same idea as keyreader/keyremap: do not steal "N" while a text input
-- widget on top of the stack has focus, otherwise typing a query (in
-- the palette, command bar, dictionary search, etc.) would pop up our
-- dialog instead of inserting the letter.
------------------------------------------------------------------

local function has_focused_input(widget, seen)
    if not widget or type(widget) ~= "table" then return false end
    seen = seen or {}
    if seen[widget] then return false end
    seen[widget] = true
    if widget.focused and widget.charlist then
        return true
    end
    for _, child in ipairs(widget) do
        if has_focused_input(child, seen) then return true end
    end
    return false
end

local function input_is_active()
    local stack = UIManager._window_stack
    if not stack or #stack == 0 then return false end
    return has_focused_input(stack[#stack].widget)
end

local function topmost_widget()
    local stack = UIManager._window_stack
    if not stack or #stack == 0 then return nil end
    return stack[#stack].widget
end

------------------------------------------------------------------
-- Modal guard for the N opener.
--
-- Same idea as Pluginaro.is_modal_active (lib/pluginaro.lua) but kept
-- local: textolimiti does not vendor/depend on pluginaro. Walks the
-- top-of-stack widget's __index metatable chain looking for one of
-- KOReader's blocking-dialog base classes, so N stands down while a
-- ConfirmBox/InfoMessage/Menu/etc. already owns the keyboard instead
-- of popping our dialog on top of it.
------------------------------------------------------------------

local MODAL_CLASS_MODULES = {
    "ui/widget/menu",
    "ui/widget/touchmenu",
    "ui/widget/inputdialog",
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/multiconfirmbox",
    "ui/widget/infomessage",
}

local modal_classes
local function get_modal_classes()
    if modal_classes then return modal_classes end
    modal_classes = {}
    for _, mod in ipairs(MODAL_CLASS_MODULES) do
        local ok, cls = pcall(require, mod)
        if ok and type(cls) == "table" then
            modal_classes[cls] = true
        end
    end
    return modal_classes
end

local function is_modal_widget(widget)
    if type(widget) ~= "table" then return false end
    local classes = get_modal_classes()
    if next(classes) == nil then return false end
    local mt = getmetatable(widget)
    local seen = {}
    while type(mt) == "table" do
        local cls = mt.__index
        if type(cls) ~= "table" then break end
        if classes[cls] then return true end
        if seen[cls] then break end
        seen[cls] = true
        mt = getmetatable(cls)
    end
    return false
end

local function is_modal_active()
    return is_modal_widget(topmost_widget())
end

------------------------------------------------------------------
-- Init
------------------------------------------------------------------

function Textolimiti:init()
    self.key_events = {
        ShowIdo  = { { "N" } },
        -- ";" and ":" only do anything when a TOC menu is open and
        -- a row is focused — they're a no-op otherwise. We bind ":"
        -- in every form KOReader's input layer might surface it:
        -- some platforms map the keysym directly (":" with no
        -- modifiers); SDL keeps the Shift modifier in the Key's
        -- modifier table even when the literal ":" character is
        -- delivered, in which case Key:match requires us to
        -- declare Shift in the sequence too.
        MarkStartFromToc = { { ";" } },
        MarkEndFromToc   = { { ":" }, { "Shift", ":" }, { "Shift", ";" } },
    }
    -- Receive key events even when sub-dialogs/menus are on top of the
    -- reader widget, the same way keyreader/visel registers itself.
    if self.ui and self.ui.active_widgets then
        table.insert(self.ui.active_widgets, self)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

------------------------------------------------------------------
-- View module registration — for paintTo corner glyphs.
-- (ReaderView is only ready inside the reader, after onReaderReady.)
------------------------------------------------------------------

function Textolimiti:onReaderReady()
    if self.view and self.view.registerViewModule then
        self.view:registerViewModule("ido_marks", self)
    end
    self:_installSetupFlowsHook()
    self:_installTocHook()
    self:_softenBoundaries()
end

------------------------------------------------------------------
-- Soft boundaries.
--
-- ReaderHandMade's setupFlows installs CreDocument.getNextPage /
-- getPrevPage on the document, both of which actively *skip* hidden
-- pages on page-turn. That's the right default for ignoring a
-- single embedded footnote section, but for our use case (front
-- matter + endnotes/bibliography) it leaves the reader stuck on
-- the last body page, unable to dip into the bibliography at all.
--
-- We replace those with Document's plain page+1 / page-1 so page
-- turns work like before custom flows existed — every page is
-- reachable. Percentage and page-count math (getPageNumberInFlow,
-- getTotalPagesInFlow, getBookProgress) still see hidden flows and
-- stay calibrated to the body.
--
-- ReaderHandMade re-plugs its methods on every setupFlows() call
-- (font change, toggle, our _refresh, etc.), so we wrap setupFlows
-- to re-apply our overrides after each invocation.
------------------------------------------------------------------

function Textolimiti:_softenBoundaries()
    local doc = self.document
    if not doc or not doc.hasHiddenFlows then return end
    doc.getNextPage = Document.getNextPage
    doc.getPrevPage = Document.getPrevPage
end

function Textolimiti:_installSetupFlowsHook()
    local h = self:_handmade()
    if not h or h._ido_hooked then return end
    local orig = h.setupFlows
    local plugin = self
    h.setupFlows = function(this, no_event)
        local ret = orig(this, no_event)
        plugin:_softenBoundaries()
        return ret
    end
    h._ido_hooked = true
end

------------------------------------------------------------------
-- TOC boundary lines.
--
-- We thicken the bottom-line color of two TOC entries to mark the
-- visual divide between front matter, body, and back matter:
--
--   * the entry just BEFORE the first body chapter  — line
--     separates introduction from body
--   * the LAST body chapter                         — line
--     separates body from endnotes / bibliography
--
-- KOReader MenuItem widgets are wrapped in an UnderlineContainer
-- whose color and linesize control the bottom rule under each row.
-- The TOC menu sets line_color = COLOR_WHITE so the rules are
-- invisible by default; we flip our two target items to
-- COLOR_BLACK + Size.line.thick. Identifying the right MenuItem
-- is done by its `idx` field, set during updateItems from the
-- toc.toc array index.
--
-- The MenuItem widgets get rebuilt on every Menu:updateItems
-- (page flip, font change, focus change), so we monkey-patch
-- updateItems on each fresh toc_menu instance and re-apply our
-- styling at the end of every rebuild.
------------------------------------------------------------------

function Textolimiti:_installTocHook()
    local toc = self.ui and self.ui.toc
    if not toc or toc._ido_hooked then return end
    local orig = toc.onShowToc
    if type(orig) ~= "function" then return end
    local plugin = self
    toc.onShowToc = function(this, ...)
        local ret = orig(this, ...)
        plugin:_markTocEntries()
        plugin:_hookTocMenuPagination()
        plugin:_hookTocMenuHold()
        plugin:_hookTocMenuPaint()
        plugin:_applyTocUnderlines()
        UIManager:setDirty(toc.toc_menu, "ui")
        return ret
    end
    toc._ido_hooked = true
end

-- Wrap the toc_menu's onMenuHold so a long-press on an entry opens a
-- 'mark as start / mark as end' ButtonDialog. Upstream's onMenuHold
-- just shows the title in an InfoMessage — we keep that as a third
-- option so the long-press still gives access to the full title.
function Textolimiti:_hookTocMenuHold()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m or m._ido_hold_hooked then return end
    local orig = m.onMenuHold
    local plugin = self
    m.onMenuHold = function(this, item, ...)
        if item then
            plugin:_showFromTocDialog(item)
            return true
        end
        if type(orig) == "function" then return orig(this, item, ...) end
        return false
    end
    m._ido_hold_hooked = true
end

-- Wrap the (fresh) toc_menu's updateItems so our bottom-line styling
-- is re-applied on every page flip / rebuild — the MenuItem widgets
-- themselves are thrown away and recreated each call, so we have to
-- re-stamp the underline color/size after each one.
function Textolimiti:_hookTocMenuPagination()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m or m._ido_paginate_hooked then return end
    local orig = m.updateItems
    if type(orig) ~= "function" then return end
    local plugin = self
    m.updateItems = function(this, ...)
        local ret = orig(this, ...)
        plugin:_applyTocUnderlines()
        return ret
    end
    m._ido_paginate_hooked = true
end

function Textolimiti:_applyTocUnderlines()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m or not m.item_group or not m.item_table then return end
    local t = self._tl_underline_thresholds
    if not t then return end

    -- The line should land under the last visible entry whose
    -- toc.toc index is < threshold, immediately followed by an
    -- entry with index >= threshold. Working from the toc.toc
    -- *flat* index means the divide naturally rides the visible
    -- depth: in collapsed view the previous-visible row is the
    -- top-level chapter; in expanded view it is the last
    -- sub-section. Same logic, different layout.
    --
    -- Within-page boundary: detected by pair-wise scan of the
    -- visible MenuItems. Page-edge boundary: detected by peeking
    -- at the very next entry in m.item_table after the last
    -- visible row (it would be the first row on the next TOC
    -- page if the threshold sits on a page break).
    local function entry_index(child)
        if not (child and child.idx) then return nil end
        local entry = m.item_table[child.idx]
        return entry and entry.index
    end
    local function crosses(a, b, th) return th and a and b and a < th and b >= th end
    local function mark(child, kind)
        if not child or not child._underline_container then return end
        child._underline_container.color = Blitbuffer.COLOR_BLACK
        child._underline_container.linesize = Size.line.thick
        -- MenuItem:onUnfocus resets _underline_container.color to
        -- self.line_color (= COLOR_WHITE for the TOC menu), so the
        -- boundary line would vanish whenever the keyboard cursor
        -- leaves a marked row. Make the row's own line_color
        -- BLACK too, so the reset lands on the colour we want.
        child.line_color = Blitbuffer.COLOR_BLACK
        -- Only decorate with the triangle if its boundary is the
        -- lonely one — both boundaries set means the layout speaks
        -- for itself.
        local show = (kind == "start" and self._tl_show_start_triangle)
                  or (kind == "end"   and self._tl_show_end_triangle)
        if show then
            self:_attachBoundaryTriangle(child, kind)
        end
    end

    local visible = {}  -- {child, toc_idx, item_table_idx}
    for _, child in ipairs(m.item_group) do
        local idx = entry_index(child)
        if idx then
            table.insert(visible, { child = child, toc_idx = idx, it_idx = child.idx })
        end
    end

    for i = 1, #visible - 1 do
        local cur, nxt = visible[i], visible[i + 1]
        if crosses(cur.toc_idx, nxt.toc_idx, t.start) then mark(cur.child, "start") end
        if crosses(cur.toc_idx, nxt.toc_idx, t.trail) then mark(cur.child, "end") end
    end

    if #visible > 0 then
        local last = visible[#visible]
        local next_entry = m.item_table[last.it_idx + 1]
        if next_entry and next_entry.index then
            if crosses(last.toc_idx, next_entry.index, t.start) then mark(last.child, "start") end
            if crosses(last.toc_idx, next_entry.index, t.trail) then mark(last.child, "end") end
        end
    end
end

-- Triangle rendering happens in two passes so the ▼ start triangle
-- can sit BELOW the line (i.e. in territory the next row owns) without
-- being overpainted when that next row draws. Pass 1 (per-MenuItem
-- paintTo wrapper) records the row's screen position. Pass 2 (menu-
-- level paintTo wrapper) walks the recorded rows and paints triangles
-- AFTER every item has finished drawing, so nothing erases them.
function Textolimiti:_triangleFace()
    if not self._triangle_face then
        self._triangle_face = Font:getFace("NotoSans-Regular", TRIANGLE_FONT_SIZE)
    end
    return self._triangle_face
end

function Textolimiti:_attachBoundaryTriangle(child, kind)
    if not child or child._tl_triangle_kind then return end
    child._tl_triangle_kind = kind
    local orig_paint = child.paintTo
    child.paintTo = function(this, bb, x, y)
        -- Record where this row landed; the menu-level paint pass
        -- uses these to draw the triangle after all rows finish.
        this._tl_screen_x = x
        this._tl_screen_y = y
        if orig_paint then orig_paint(this, bb, x, y) end
    end
end

function Textolimiti:_hookTocMenuPaint()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m or m._ido_paint_hooked then return end
    local orig = m.paintTo
    if type(orig) ~= "function" then return end
    local plugin = self
    m.paintTo = function(this, bb, x, y)
        orig(this, bb, x, y)
        plugin:_paintAllBoundaryTriangles(this, bb)
    end
    m._ido_paint_hooked = true
end

function Textolimiti:_paintAllBoundaryTriangles(menu, bb)
    if not menu or not menu.item_group then
        logger.dbg("textolimiti: paintAll — no menu or item_group")
        return
    end
    local n_total, n_marked, n_paint = 0, 0, 0
    for _, child in ipairs(menu.item_group) do
        n_total = n_total + 1
        if child and child._tl_triangle_kind then
            n_marked = n_marked + 1
        end
        if child and child._tl_triangle_kind
                 and child._tl_screen_x and child._tl_screen_y
                 and child.dimen and child.dimen.w and child.dimen.h then
            n_paint = n_paint + 1
            self:_paintBoundaryTriangle(bb, child)
        end
    end
    logger.dbg(string.format(
        "textolimiti: paintAll total=%d marked=%d painted=%d show_start=%s show_end=%s",
        n_total, n_marked, n_paint,
        tostring(self._tl_show_start_triangle),
        tostring(self._tl_show_end_triangle)))
end

function Textolimiti:_paintBoundaryTriangle(bb, item)
    local kind = item._tl_triangle_kind
    local d = item.dimen
    local x, y = item._tl_screen_x, item._tl_screen_y
    local glyph = (kind == "start") and START_TRIANGLE or END_TRIANGLE
    local w = TextWidget:new{
        text    = glyph,
        face    = self:_triangleFace(),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local size = w:getSize()
    local thick = Size.line.thick
    local px = x + math.floor((d.w - size.w) / 2)
    local py
    if kind == "start" then
        -- ▼ below the line: triangle top edge sits at the line bottom,
        -- with a 1-pixel gap so it does not visually merge with the
        -- rule.
        py = y + d.h + 1
    else
        -- ▲ above the line: triangle bottom edge sits just above the
        -- line top, mirroring the start position.
        py = y + d.h - thick - size.h - 1
    end
    w:paintTo(bb, px, py)
    w:free()
end

function Textolimiti:_repaintTocMenu()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m then return end
    if m.updateItems then
        m:updateItems(1, true)  -- triggers our wrapped version → re-applies underlines
    end
    UIManager:setDirty(m, "ui")
end

function Textolimiti:_markTocEntries()
    -- Reset thresholds each time we recompute.
    self._tl_underline_thresholds = nil

    local toc = self:_toc()
    if not toc or not toc.toc then return end

    local handmade = self:_handmade()
    if not handmade or not handmade.flows_enabled then return end
    local points = handmade.flow_points
    if not points or #points == 0 then return end

    local lead  = self:_findLeadingZone(points)
    local trail = self:_findTrailingZone(points)
    local start_xp = lead and lead.restart_idx and points[lead.restart_idx].xpointer
    local trail_xp = trail and points[trail.hidden_idx].xpointer

    -- Match TOC entries by anchor. CRENGINE may write the same DOM
    -- position in several equivalent forms (e.g. `/h1.0` vs
    -- `/h1/text()[1].0`), so a literal string compare misses real
    -- matches across reflow / re-renders / sessions. We try three
    -- tiers, falling back if the previous one fails:
    --
    --   1. Literal xpointer string equality (fast path).
    --   2. compareXPointers (engine-level semantic equality).
    --   3. Resolved page-number equality (xp → getPageFromXPointer
    --      → match e.page). This bypasses xpointer notation
    --      entirely — same heading element always resolves to the
    --      same page within a given rendering, regardless of how
    --      its xpointer was written down.
    local doc = self.document
    local function same_xp(a, b)
        if not a or not b then return false end
        if a == b then return true end
        if doc and doc.compareXPointers then
            local ok, ord = pcall(doc.compareXPointers, doc, a, b)
            if ok and ord == 0 then return true end
        end
        return false
    end
    local function page_of(xp)
        if not xp or not doc or not doc.getPageFromXPointer then return nil end
        local ok, p = pcall(doc.getPageFromXPointer, doc, xp)
        if ok and type(p) == "number" and p > 0 then return p end
    end
    -- Prefer the stored .page on the flow point itself: ReaderHandMade
    -- keeps it fresh via updateHandmagePages on every render. Fall back
    -- to resolving the xpointer if .page is missing.
    local start_page = (lead and lead.restart_idx and points[lead.restart_idx].page)
                       or page_of(start_xp)
    local trail_page = (trail and points[trail.hidden_idx].page)
                       or page_of(trail_xp)

    local start_idx, trail_idx
    for i, e in ipairs(toc.toc) do
        if start_xp and not start_idx and same_xp(e.xpointer, start_xp) then start_idx = i end
        if trail_xp and not trail_idx and same_xp(e.xpointer, trail_xp) then trail_idx = i end
    end
    if not start_idx and start_page then
        for i, e in ipairs(toc.toc) do
            if e.page == start_page then start_idx = i; break end
        end
    end
    if not trail_idx and trail_page then
        for i, e in ipairs(toc.toc) do
            if e.page == trail_page then trail_idx = i; break end
        end
    end
    -- Off-by-one tolerance: under some renderings a chapter heading
    -- spills onto the previous or next page from where the saved
    -- point originally landed. Accept any TOC entry within ±1 page.
    if not start_idx and start_page then
        for i, e in ipairs(toc.toc) do
            if e.page == start_page - 1 or e.page == start_page + 1 then
                start_idx = i; break
            end
        end
    end
    if not trail_idx and trail_page then
        for i, e in ipairs(toc.toc) do
            if e.page == trail_page - 1 or e.page == trail_page + 1 then
                trail_idx = i; break
            end
        end
    end
    -- Store toc.toc thresholds (= the first body chapter, and the
    -- first hidden chapter). The applier draws the line under the
    -- last visible row whose entry.index is strictly below each
    -- threshold — so the divide always lands on whatever the user
    -- can actually see (collapsed top-level vs. expanded sub-section).
    local thresholds = {}
    local has_start = start_idx and start_idx > 1
    local has_trail = trail_idx and trail_idx > 1
    if has_start then thresholds.start = start_idx end
    if has_trail then thresholds.trail = trail_idx end
    if next(thresholds) then
        self._tl_underline_thresholds = thresholds
        -- Triangles act as a "which boundary is this?" hint while the
        -- user is mid-marking. Once BOTH boundaries are set, the
        -- layout itself (intro · body · back-matter) makes their roles
        -- obvious and the triangles only add clutter. So we show each
        -- triangle only when its boundary is the *lonely* one.
        self._tl_show_start_triangle = has_start and not has_trail
        self._tl_show_end_triangle   = has_trail and not has_start
    end
end

function Textolimiti:_glyphFace()
    if not self._glyph_face then
        self._glyph_face = Font:getFace("NotoSans-Regular", MANICULE_FONT_SIZE)
    end
    return self._glyph_face
end

------------------------------------------------------------------
-- Handmade helpers
------------------------------------------------------------------

function Textolimiti:_handmade()
    return self.ui and self.ui.handmade
end

function Textolimiti:_currentPage()
    if not self.ui or not self.ui.getCurrentPage then return nil end
    return self.ui:getCurrentPage()
end

function Textolimiti:_pageCount()
    if not self.document or not self.document.getPageCount then return nil end
    return self.document:getPageCount()
end

-- Build a flow-point item the same way ReaderHandMade:toggleHiddenFlow
-- does — including the xpointer for rolling (CRE) documents, so the
-- point survives reflow / font-size changes.
function Textolimiti:_makePoint(pageno, hidden)
    local xpointer
    if self.ui.rolling and type(pageno) == "number" and self.document.getPageXPointer then
        xpointer = self.document:getPageXPointer(pageno)
    end
    return {
        page     = pageno,
        hidden   = hidden,
        xpointer = xpointer,
    }
end

-- After mutating flow_points: enable flows if needed, recompute,
-- refresh footer/toc.
--
-- We pass `silent = true` to setupFlows so it skips its UpdateToc /
-- InitScrollPageStates broadcasts. UpdateToc's default handler
-- (ReaderToc:onUpdateToc) calls close_callback on the open TOC menu,
-- which is why marking from inside the TOC used to make the menu
-- vanish — and the boundary line with it, until the user re-opened
-- it. Our flow_point edits don't change the TOC structure (no entries
-- added or removed), only the page-number anchors, so the rebuild
-- those events trigger is unnecessary. We do the *useful* parts of
-- the refresh — footer percentage, our boundary underlines — by hand
-- right below.
function Textolimiti:_refresh()
    local handmade = self:_handmade()
    if not handmade then return end
    if not handmade.flows_enabled then
        handmade.flows_enabled = true
    end
    handmade:setupFlows(true)  -- silent: no UpdateToc / InitScrollPageStates
    if self.ui.annotation then
        self.ui.annotation:setNeedsUpdateFlag()
    end
    if self.view and self.view.footer then
        self.view.footer:maybeUpdateFooter()
    end
    -- Re-stamp TOC underline thresholds and force the open TOC menu
    -- (if any) to repaint with the new boundary lines in place.
    self:_markTocEntries()
    self:_repaintTocMenu()
end

------------------------------------------------------------------
-- Leading- and trailing-zone classification
--
-- Flow points live in a page-sorted list. A "leading zone" hides the
-- run from page 1 up to some restart point; a "trailing zone" hides
-- everything from some hidden point to the last page. The user's
-- start/end actions only touch those zones, never interior points
-- that the built-in Page-browser UI may have created.
------------------------------------------------------------------

-- Return the indices of the leading hidden zone, if any:
--   {hidden_idx, restart_idx_or_nil}
-- A leading zone starts with a hidden point at page 1, followed by an
-- optional restart (non-hidden) point at some later page.
function Textolimiti:_findLeadingZone(points)
    if #points == 0 then return nil end
    local first = points[1]
    if not (first.hidden and first.page == 1) then return nil end
    local restart_idx
    for i = 2, #points do
        if not points[i].hidden then
            restart_idx = i
            break
        end
    end
    return { hidden_idx = 1, restart_idx = restart_idx }
end

-- Return the indices of the trailing hidden zone, if any:
--   {hidden_idx}
-- A trailing zone starts at a hidden point with no following restart.
function Textolimiti:_findTrailingZone(points)
    if #points == 0 then return nil end
    local last_hidden_idx
    for i = #points, 1, -1 do
        if not points[i].hidden then
            -- Found a restart after the (possible) trailing-hidden run,
            -- so anything before it is not the trailing zone.
            return last_hidden_idx and { hidden_idx = last_hidden_idx } or nil
        end
        last_hidden_idx = i
    end
    -- All points are hidden — the very first one is the trailing zone's
    -- hidden start. (And it is also the leading zone if its page == 1;
    -- start/end actions handle that overlap by deleting and re-inserting.)
    return last_hidden_idx and { hidden_idx = last_hidden_idx } or nil
end

-- Locate the anchor pages: where body text starts and where it ends,
-- derived from the leading/trailing hidden zones. These are the pages
-- the manicule glyphs decorate.
function Textolimiti:_anchorPages()
    local h = self:_handmade()
    if not h or not h.flow_points or #h.flow_points == 0 then
        return nil, nil
    end
    local pts = h.flow_points
    local starts_at, ends_at
    local lead = self:_findLeadingZone(pts)
    if lead and lead.restart_idx then
        starts_at = pts[lead.restart_idx].page
    end
    local trail = self:_findTrailingZone(pts)
    if trail then
        ends_at = pts[trail.hidden_idx].page - 1
    end
    return starts_at, ends_at
end

-- Insert into a page-sorted list, keeping ordering invariant.
local function insert_sorted(points, item)
    local insertion_idx = #points + 1
    for i, p in ipairs(points) do
        if p.page > item.page then
            insertion_idx = i
            break
        end
    end
    table.insert(points, insertion_idx, item)
end

------------------------------------------------------------------
-- TOC navigation.
--
-- Anchoring marks to a TOC section instead of a page makes them
-- survive font-size / margin / line-height changes cleanly. The TOC
-- entry's xpointer is a stable DOM anchor (chapter heading), so the
-- page derived from it tracks the heading rather than wherever the
-- last reflow happened to put a mid-paragraph cursor.
--
-- For end-of-body, we anchor at the FIRST page of the chapter AFTER
-- the user's chosen "last body chapter" — the trailing hidden zone
-- thus starts cleanly at the next chapter's heading.
------------------------------------------------------------------

function Textolimiti:_toc()
    local toc = self.ui and self.ui.toc
    if not toc then return nil end
    -- Ensure self.toc is populated. fillToc() is idempotent.
    if toc.fillToc then toc:fillToc() end
    return toc
end

-- The TOC entry that contains the given (or current) page —
-- the largest entry whose .page is <= the target page.
function Textolimiti:_sectionAt(pageno)
    local toc = self:_toc()
    if not toc or not toc.toc or #toc.toc == 0 then return nil end
    local page = pageno or self:_currentPage()
    if not page then return nil end
    local idx = toc:getTocIndexByPage(page)
    if not idx then return nil end
    return idx, toc.toc[idx]
end

-- The TOC entry immediately AFTER the given (or current) page —
-- the first entry whose .page is strictly greater. nil if none.
function Textolimiti:_sectionAfter(pageno)
    local idx = self:_sectionAt(pageno)
    if not idx then return nil end
    local toc = self:_toc()
    local next_idx = idx + 1
    local entry = toc and toc.toc and toc.toc[next_idx]
    if not entry then return nil end
    return next_idx, entry
end

-- Build a flow-point item anchored to a TOC entry. The xpointer is
-- the stable anchor; ReaderHandMade's updateHandmagePages will keep
-- .page in sync on every rerender by re-resolving the xpointer.
function Textolimiti:_makeSectionPoint(entry, hidden)
    -- Trust the xpointer; recompute page from it for the current
    -- rendering so the in-memory state matches what the document
    -- sees right now (entry.page may be stale if the document has
    -- reflowed since the TOC was filled).
    local page = entry.page
    if self.document.getPageFromXPointer and entry.xpointer then
        local p = self.document:getPageFromXPointer(entry.xpointer)
        if p and p > 0 then page = p end
    end
    return {
        page     = page,
        hidden   = hidden,
        xpointer = entry.xpointer,
    }
end

------------------------------------------------------------------
-- Public actions
------------------------------------------------------------------

-- Apply a leading hidden zone whose restart anchor is the given TOC
-- entry. Replaces any prior leading zone. entry.page == 1 (or no
-- entry) clears the leading zone entirely.
function Textolimiti:_applyStartAtSection(entry)
    local handmade = self:_handmade()
    local points = handmade.flow_points

    local lead = self:_findLeadingZone(points)
    if lead then
        if lead.restart_idx then
            table.remove(points, lead.restart_idx)
        end
        table.remove(points, lead.hidden_idx)
    end

    local restart_page = entry and entry.page or 1
    if self.document.getPageFromXPointer and entry and entry.xpointer then
        local p = self.document:getPageFromXPointer(entry.xpointer)
        if p and p > 0 then restart_page = p end
    end

    if restart_page > 1 then
        insert_sorted(points, self:_makePoint(1, true))
        insert_sorted(points, self:_makeSectionPoint(entry, false))
    end

    self:_refresh()
    if restart_page > 1 then
        self:_notify(T(_("Komenco: «%1» (p. %2)"),
            entry and entry.title or "?", restart_page))
    else
        self:_notify(_("Komenco-marko forigita"))
    end
end

-- Apply a trailing hidden zone that starts at the given TOC entry's
-- xpointer. Replaces any prior trailing zone. nil entry clears the
-- trailing zone (no hiding past the last body page).
function Textolimiti:_applyEndBeforeSection(entry)
    local handmade = self:_handmade()
    local points = handmade.flow_points

    local trail = self:_findTrailingZone(points)
    if trail then
        table.remove(points, trail.hidden_idx)
    end

    if entry then
        insert_sorted(points, self:_makeSectionPoint(entry, true))
    end

    self:_refresh()
    if entry then
        self:_notify(T(_("Fino antaŭ «%1»"), entry.title or "?"))
    else
        self:_notify(_("Fino-marko forigita"))
    end
end

-- "Starts here" = "the current chapter is the first body chapter".
-- Falls back to per-page anchoring if the book has no TOC.
function Textolimiti:setStartHere()
    local handmade = self:_handmade()
    if not handmade then
        return self:_warnNoHandmade()
    end
    local _, entry = self:_sectionAt()
    if entry then
        return self:_applyStartAtSection(entry)
    end
    -- No TOC: anchor to the current page's xpointer.
    local page = self:_currentPage()
    if not page then
        return UIManager:show(InfoMessage:new{
            text = _("Ne eblas determini la aktualan paĝon."),
        })
    end
    local points = handmade.flow_points
    local lead = self:_findLeadingZone(points)
    if lead then
        if lead.restart_idx then table.remove(points, lead.restart_idx) end
        table.remove(points, lead.hidden_idx)
    end
    if page > 1 then
        insert_sorted(points, self:_makePoint(1, true))
        insert_sorted(points, self:_makePoint(page, false))
    end
    self:_refresh()
    if page > 1 then
        self:_notify(T(_("Kaŝitaj p. 1–%1"), page - 1))
    else
        self:_notify(_("Komenco-marko forigita"))
    end
end

-- "Ends here" = "the current chapter is the last body chapter".
-- The trailing hidden zone starts at the NEXT chapter's xpointer.
-- Falls back to per-page anchoring if no TOC.
function Textolimiti:setEndHere()
    local handmade = self:_handmade()
    if not handmade then
        return self:_warnNoHandmade()
    end
    local _, next_entry = self:_sectionAfter()
    if self:_sectionAt() then
        -- TOC present: anchor by section (next_entry may be nil if
        -- we're in the last chapter — then there is no trail).
        return self:_applyEndBeforeSection(next_entry)
    end
    -- No TOC: per-page fallback.
    local page = self:_currentPage()
    local total = self:_pageCount()
    if not page or not total then
        return UIManager:show(InfoMessage:new{
            text = _("Ne eblas determini la paĝo-nombron."),
        })
    end
    local points = handmade.flow_points
    local trail = self:_findTrailingZone(points)
    if trail then table.remove(points, trail.hidden_idx) end
    if page < total then
        insert_sorted(points, self:_makePoint(page + 1, true))
    end
    self:_refresh()
    if page < total then
        self:_notify(T(_("Kaŝitaj p. %1–%2"), page + 1, total))
    else
        self:_notify(_("Fino-marko forigita"))
    end
end

function Textolimiti:clearAll()
    local handmade = self:_handmade()
    if not handmade then return end
    if #handmade.flow_points == 0 then return end
    UIManager:show(ConfirmBox:new{
        text = _("Forigi ĉiujn limmarkojn?"),
        ok_callback = function()
            handmade.flow_points = {}
            self:_refresh()
            self:_notify(_("Ĉiuj limmarkoj forigitaj"))
        end,
    })
end

function Textolimiti:toggleFlows()
    local handmade = self:_handmade()
    if not handmade then return end
    handmade:onToggleHandmadeFlows()
    self:_notify(handmade.flows_enabled
        and _("Kaŝitaj fluoj: ŝaltita")
        or  _("Kaŝitaj fluoj: malŝaltita"))
end

------------------------------------------------------------------
-- TOC section picker
--
-- Shows a scrollable list of every chapter in the TOC, indented by
-- depth, page number on the right. The picked entry is passed to
-- the caller's `on_pick` callback. Used for both "choose start
-- chapter" and "choose end chapter".
------------------------------------------------------------------

function Textolimiti:_pickSection(title, on_pick)
    local toc = self:_toc()
    if not toc or not toc.toc or #toc.toc == 0 then
        return UIManager:show(InfoMessage:new{
            text = _("Ĉi tiu libro ne havas enhavtabelon."),
        })
    end
    local items = {}
    for i, entry in ipairs(toc.toc) do
        local indent = string.rep("  ", math.max(0, (entry.depth or 1) - 1))
        local label  = entry.title and entry.title ~= "" and entry.title or "—"
        table.insert(items, {
            text     = string.format("%s%s", indent, label),
            mandatory = tostring(entry.page or "?"),
            entry    = entry,
        })
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._section_picker = Menu:new{
        title          = title,
        item_table     = items,
        is_borderless  = false,
        is_popout      = false,
        width          = math.floor(sw * 0.92),
        height         = math.floor(sh * 0.88),
        single_line    = true,
        items_per_page = 14,
        items_font_size = Menu.getItemFontSize(14),
        close_callback = function()
            self._section_picker = nil
        end,
    }
    self._section_picker.onMenuChoice = function(_menu, item)
        if item and item.entry then on_pick(item.entry) end
    end
    UIManager:show(self._section_picker)
end

function Textolimiti:_pickStartSection()
    self:_pickSection(_("Elekti komencan ĉapitron"), function(entry)
        self:_applyStartAtSection(entry)
    end)
end

function Textolimiti:_pickEndSection()
    -- Picker semantics: choose the last body chapter. The trailing
    -- hidden zone then starts at the NEXT chapter.
    local toc = self:_toc()
    if not toc then
        return UIManager:show(InfoMessage:new{
            text = _("Ĉi tiu libro ne havas enhavtabelon."),
        })
    end
    self:_pickSection(_("Lasta korpa ĉapitro"), function(entry)
        local picked_idx
        for i, e in ipairs(toc.toc) do
            if e == entry then picked_idx = i; break end
        end
        local next_entry = picked_idx and toc.toc[picked_idx + 1]
        self:_applyEndBeforeSection(next_entry)
    end)
end

------------------------------------------------------------------
-- Marks list dialog
------------------------------------------------------------------

function Textolimiti:_showMarksList()
    local handmade = self:_handmade()
    if not handmade then return end
    local points = handmade.flow_points
    if #points == 0 then
        return UIManager:show(InfoMessage:new{
            text = _("Neniuj limmarkoj."),
        })
    end

    local buttons = {}
    for i, p in ipairs(points) do
        local label = T(p.hidden and _("p. %1 — kaŝa") or _("p. %1 — regula"), p.page)
        table.insert(buttons, {{
            text = "✕  " .. label,
            align = "left",
            callback = function()
                table.remove(handmade.flow_points, i)
                self:_refresh()
                UIManager:close(self._marks_dialog)
                self._marks_dialog = nil
                self:_notify(_("Marko forigita"))
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Forigi ĉiujn"),
        callback = function()
            UIManager:close(self._marks_dialog)
            self._marks_dialog = nil
            self:clearAll()
        end,
    }})
    table.insert(buttons, {{
        text = _("Fermi"),
        callback = function()
            UIManager:close(self._marks_dialog)
            self._marks_dialog = nil
        end,
    }})

    self._marks_dialog = ButtonDialog:new{
        title         = _("Textolimiti — markoj"),
        title_align   = "center",
        shrink_unneeded_width = true,
        buttons       = buttons,
    }
    UIManager:show(self._marks_dialog)
end

------------------------------------------------------------------
-- UI plumbing
------------------------------------------------------------------

function Textolimiti:_warnNoHandmade()
    UIManager:show(InfoMessage:new{
        text = _("KOReader 'custom hidden flows' ne disponeblas en ĉi tiu konstruo."),
    })
end

function Textolimiti:_notify(text)
    -- Notification:notify shows a top-of-screen toast that
    -- auto-dismisses, no interaction required.
    pcall(Notification.notify, Notification, text)
end

function Textolimiti:onShowIdo()
    if input_is_active() then return false end
    if is_modal_active() then return false end
    self:_showMainDialog()
    return true
end

function Textolimiti:_showMainDialog()
    if not self:_handmade() then
        return self:_warnNoHandmade()
    end

    local page = self:_currentPage() or "?"
    local handmade = self:_handmade()
    local n_marks = #handmade.flow_points
    local _, section = self:_sectionAt()
    local section_title = section and section.title and section.title ~= "" and section.title or nil

    local title
    if section_title then
        title = T(_("Textolimiti · p. %1 · «%2»"), page, section_title)
    else
        title = T(_("Textolimiti · p. %1"), page)
    end

    local close = function() UIManager:close(self._main_dialog); self._main_dialog = nil end

    local buttons = {
        {{
            text = _("La teksto komenciĝas ĉi tie"),
            align = "left",
            callback = function() close(); self:setStartHere() end,
        }},
        {{
            text = _("La teksto finiĝas ĉi tie"),
            align = "left",
            callback = function() close(); self:setEndHere() end,
        }},
        {{
            text = _("Elekti komencan ĉapitron…"),
            align = "left",
            callback = function() close(); self:_pickStartSection() end,
        }},
        {{
            text = _("Elekti lastan ĉapitron…"),
            align = "left",
            callback = function() close(); self:_pickEndSection() end,
        }},
        {{
            text = T(_("Montri · forigi markojn (%1)"), n_marks),
            align = "left",
            callback = function() close(); self:_showMarksList() end,
        }},
        {{
            text = handmade.flows_enabled
                and _("Malŝalti kaŝitajn fluojn")
                or  _("Ŝalti kaŝitajn fluojn"),
            align = "left",
            callback = function() close(); self:toggleFlows() end,
        }},
        {{
            text = _("Nuligi"),
            callback = close,
        }},
    }

    self._main_dialog = ButtonDialog:new{
        title         = title,
        title_align   = "center",
        shrink_unneeded_width = true,
        buttons       = buttons,
    }
    UIManager:show(self._main_dialog)
end

------------------------------------------------------------------
-- Main menu entry — also makes the actions reachable from the
-- command palette (keyreader O).
------------------------------------------------------------------

function Textolimiti:addToMainMenu(menu_items)
    menu_items.textolimiti = {
        text         = _("Textolimiti"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text           = _("Malfermi dialogon (N)"),
                callback       = function() self:_showMainDialog() end,
                keep_menu_open = false,
            },
            {
                text      = _("La teksto komenciĝas ĉi tie"),
                help_text = _("Marki la aktualan ĉapitron kiel la unuan korpan ĉapitron."),
                callback  = function() self:setStartHere() end,
                keep_menu_open = false,
            },
            {
                text      = _("La teksto finiĝas ĉi tie"),
                help_text = _("Marki la aktualan ĉapitron kiel la lastan korpan ĉapitron."),
                callback  = function() self:setEndHere() end,
                keep_menu_open = false,
            },
            {
                text           = _("Elekti komencan ĉapitron…"),
                callback       = function() self:_pickStartSection() end,
                keep_menu_open = false,
                separator      = true,
            },
            {
                text           = _("Elekti lastan korpan ĉapitron…"),
                callback       = function() self:_pickEndSection() end,
                keep_menu_open = false,
                separator      = true,
            },
            {
                text           = _("Montri · forigi markojn"),
                callback       = function() self:_showMarksList() end,
                keep_menu_open = false,
            },
            {
                text         = _("Baskuli kaŝitajn fluojn"),
                checked_func = function()
                    local h = self:_handmade()
                    return h and h.flows_enabled or false
                end,
                callback     = function() self:toggleFlows() end,
            },
        },
    }
end

------------------------------------------------------------------
-- Marking from inside the TOC
--
-- Keyboard:  ; on a focused row → mark that chapter as body-start
--            : on a focused row → mark that chapter as last body chapter
-- Touch:     long-press a row → ButtonDialog with both choices
--
-- Both go through the same section-anchored apply functions used by
-- the picker (_applyStartAtSection / _applyEndBeforeSection), so the
-- saved xpointer survives reflow exactly the same way.
------------------------------------------------------------------

-- Resolve the TOC entry that the FocusManager currently has selected.
function Textolimiti:_focusedTocEntry()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    if not m or not m.selected or not m.layout or not m.item_table then
        return nil
    end
    local sel = m.selected
    local row = m.layout[sel.y]
    local widget = row and row[sel.x]
    if not widget or not widget.idx then return nil end
    return m.item_table[widget.idx]
end

-- Treat the chapter as "first body chapter".
function Textolimiti:_markAsStart(entry)
    if not entry then return end
    if not self:_handmade() then
        return self:_warnNoHandmade()
    end
    self:_applyStartAtSection(entry)
end

-- Treat the chapter as "last body chapter" — trail goes to the NEXT
-- TOC entry. nil next_entry means body extends to the end of the book.
function Textolimiti:_markAsEnd(entry)
    if not entry then return end
    if not self:_handmade() then
        return self:_warnNoHandmade()
    end
    local toc = self.ui and self.ui.toc
    if not toc or not toc.toc then return end
    local picked_idx
    for i, e in ipairs(toc.toc) do
        if e == entry then picked_idx = i; break end
    end
    local next_entry = picked_idx and toc.toc[picked_idx + 1] or nil
    self:_applyEndBeforeSection(next_entry)
end

-- ";" / ":" are only meaningful while the TOC menu itself is the
-- topmost window — that is the state _focusedTocEntry() reads from.
-- If something is stacked ON TOP of the TOC menu (our own long-press
-- ButtonDialog, a ConfirmBox, …), _focusedTocEntry() would still
-- happily return the row that was focused before that dialog opened,
-- silently bypassing it. Requiring the TOC menu to be exactly the
-- topmost widget closes that gap without blocking the normal case
-- (TOC menu itself is a modal Menu, so a blanket is_modal_active()
-- check would reject the very state these keys are meant to work in).
function Textolimiti:_tocMenuIsTopmost()
    local toc = self.ui and self.ui.toc
    local m = toc and toc.toc_menu
    return m ~= nil and topmost_widget() == m
end

function Textolimiti:onMarkStartFromToc()
    if input_is_active() then return false end
    if not self:_tocMenuIsTopmost() then return false end
    local entry = self:_focusedTocEntry()
    if not entry then return false end
    self:_markAsStart(entry)
    return true
end

function Textolimiti:onMarkEndFromToc()
    if input_is_active() then return false end
    if not self:_tocMenuIsTopmost() then return false end
    local entry = self:_focusedTocEntry()
    if not entry then return false end
    self:_markAsEnd(entry)
    return true
end

function Textolimiti:_showFromTocDialog(entry)
    local title = entry and entry.title and entry.title ~= "" and entry.title or "?"
    local close = function()
        if self._toc_pick_dialog then
            UIManager:close(self._toc_pick_dialog)
            self._toc_pick_dialog = nil
        end
    end
    local buttons = {
        {{
            text     = _("La teksto komenciĝas ĉi tie"),
            align    = "left",
            callback = function() close(); self:_markAsStart(entry) end,
        }},
        {{
            text     = _("La teksto finiĝas ĉi tie"),
            align    = "left",
            callback = function() close(); self:_markAsEnd(entry) end,
        }},
        {{
            text     = _("Nuligi"),
            callback = close,
        }},
    }
    self._toc_pick_dialog = ButtonDialog:new{
        title         = T(_("«%1»"), title),
        title_align   = "center",
        shrink_unneeded_width = true,
        buttons       = buttons,
    }
    UIManager:show(self._toc_pick_dialog)
end

------------------------------------------------------------------
-- Corner manicules + hidden-zone footer mask.
--
-- Registered as a view module, so paintTo is called by ReaderView on
-- every render — after the page content AND after the footer. We do
-- two things, depending on where the current page sits:
--
--   * In the body: draw ☞ in the upper-left corner of the start
--     page and ☜ in the upper-right of the end page.
--   * In a hidden zone (front matter or bibliography): overpaint the
--     footer's strip with the page background, so the misleading
--     percentage / page count / progress bar disappear. The footer
--     is calibrated to body pages; outside of those, the numbers are
--     meaningless ("[12%]"-bracketed bookmarks for a flow you're not
--     tracking). Hiding the strip is the cleanest visual signal that
--     you've stepped past the bounds.
--
-- Both branches only run when hidden flows are enabled — otherwise
-- the user sees the full untruncated page count and there's nothing
-- to mark or mask.
------------------------------------------------------------------

function Textolimiti:_maskFooter(bb)
    local footer = self.view and self.view.footer
    if not footer then return end
    local footer_h = footer.getHeight and footer:getHeight() or 0
    if not footer_h or footer_h <= 0 then return end
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local bg = (self.view and self.view.page_bgcolor) or Blitbuffer.COLOR_WHITE
    bb:paintRect(0, sh - footer_h, sw, footer_h, bg)
end

function Textolimiti:paintTo(bb, x, y)
    local h = self:_handmade()
    if not h or not h.flows_enabled then return end
    local starts_at, ends_at = self:_anchorPages()
    if not starts_at and not ends_at then return end
    local cur = self:_currentPage()
    if not cur then return end

    -- Outside the body? Hide the footer strip and skip manicules.
    if h.isInHiddenFlow and h:isInHiddenFlow(cur) then
        self:_maskFooter(bb)
        return
    end

    local margin = Size.padding.large
    if cur == starts_at then
        local w = TextWidget:new{ text = START_GLYPH, face = self:_glyphFace() }
        w:paintTo(bb, x + margin, y + margin)
        w:free()
    end
    if cur == ends_at then
        local w = TextWidget:new{ text = END_GLYPH, face = self:_glyphFace() }
        local size = w:getSize()
        w:paintTo(bb, x + Screen:getWidth() - size.w - margin, y + margin)
        w:free()
    end
end

return Textolimiti
