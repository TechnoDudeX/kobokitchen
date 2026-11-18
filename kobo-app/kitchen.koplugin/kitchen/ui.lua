--[[
The kitchen recipe box: the screens. One full-screen widget that draws whichever screen is
showing and takes every tap, hold, swipe and key itself, so nothing ever reaches KOReader
underneath.

    home     the Recipe box: the title, one big tile per chapter, A to Z, How it works
    chapter  one big button per recipe (a few per page, with Back / More buttons when needed)
    letters  A to Z: one big button per letter
    letter   the recipes under one letter
    recipe   the recipe, in pages: what you need, how to make it, the notes
    cook     cooking mode: one step per screen, big Back / Next
    done     "Enjoy!"
    how      how it works, the edition, and "Get new recipes" (only when Wi-Fi updates are set up)

Every button is a whole area to tap (a tap a little outside still counts if nothing else is
closer), and pressing a little longer counts as a tap too. Swiping left or right turns pages
and steps. Holding a finger on the big title of the Recipe box (or of How it works) opens a
small menu for whoever looks after the Kobo.
]]
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local Data = require("kitchen/data")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY

--[[ Sizes. Everything is laid out for the Kobo Aura HD's 1080 x 1440 screen and scaled for any
other size (the Mac preview, another Kobo). px(n) is n of those pixels on this screen. ]]
local S = {}
local function px(n)
    return math.floor(n * S.u + 0.5)
end

-- Fonts. Font:getFace multiplies the size it is given by the screen's scale (1.8 on the Aura
-- HD), so ask for the size that comes out as the wanted number of pixels. S.fonts has the
-- handwriting fonts (from main.lua); KOReader's own fonts stand in for any that are missing.
local function face(kind, size)
    local unit = Screen:scaleBySize(1000) / 1000
    local want = math.max(6, math.floor(size / unit + 0.5))
    local f
    local name = (not S.plain_font) and S.fonts and S.fonts[kind]
    if name then f = Font:getFace(name, want) end
    return f or Font:getFace(kind == "title" and "tfont" or "cfont", want)
end

local function text(str, kind, size, max_width)
    return TextWidget:new{
        text = str,
        face = face(kind, size),
        fgcolor = BLACK,
        max_width = max_width,
    }
end

-- A one-line label made smaller (down to `smallest`) until it fits `width`.
local function fittedText(str, kind, size, width, smallest)
    smallest = smallest or math.floor(size * 0.7)
    local t = text(str, kind, size)
    while t:getSize().w > width and size > smallest do
        t:free()
        size = size - math.max(1, math.floor(size * 0.06))
        t = text(str, kind, size)
    end
    if t:getSize().w > width then
        t:free()
        t = text(str, kind, size, width) -- still too long: cut with "…"
    end
    return t
end

local function textBox(str, kind, size, width, alignment, line_height)
    return TextBoxWidget:new{
        text = str,
        face = face(kind, size),
        fgcolor = BLACK,
        width = width,
        alignment = alignment or "left",
        line_height = line_height or 0.2,
    }
end

local function image(path, w, h)
    if not path then return nil end
    return ImageWidget:new{
        file = path,
        width = w,
        height = h,
        scale_factor = 0,      -- fit inside w x h, keeping the shape
        alpha = true,          -- the doodles have see-through backgrounds
        file_do_cache = false, -- new recipes can bring a new picture under the same name
    }
end

-- A box of exactly w x h holding `child`, centred (or `align` = "left" / "right").
local function box(w, h, child, align)
    local Container = (align == "left" and LeftContainer) or (align == "right" and RightContainer) or CenterContainer
    return Container:new{ dimen = Geom:new{ w = w, h = h }, child }
end

-- A framed area of exactly w x h (border included), its child centred inside.
local function frame(w, h, child, opts)
    opts = opts or {}
    local b = opts.border or px(5)
    return FrameContainer:new{
        bordersize = b,
        radius = opts.radius or px(26),
        padding = 0,
        margin = 0,
        background = WHITE,
        color = BLACK,
        box(w - 2 * b, h - 2 * b, child),
    }
end

-- A column of widgets. (Groups remember their size the first time it is asked for, so a group
-- is only measured once it is complete; the screens add up the heights of finished pieces.)
local function vgroup(items, align)
    local g = VerticalGroup:new{ align = align or "left" }
    for _, it in ipairs(items) do table.insert(g, it) end
    return g
end

local function vspan(h) return VerticalSpan:new{ width = h } end
local function hspan(w) return HorizontalSpan:new{ width = w } end

local function line(w, h, color)
    return LineWidget:new{ dimen = Geom:new{ w = w, h = h or px(3) }, background = color or GRAY }
end

-- "made with love {heart} for ..." with the heart drawn as the little doodle.
local function withHeart(str, kind, size, heart_path)
    local parts = {}
    local rest = str
    while true do
        local a, b = rest:find("{heart}", 1, true)
        if not a then break end
        if a > 1 then table.insert(parts, text(rest:sub(1, a - 1), kind, size)) end
        local h = image(heart_path, math.floor(size * 0.8), math.floor(size * 0.8))
        table.insert(parts, h or text("♥", "text", size))
        rest = rest:sub(b + 1)
    end
    if rest ~= "" then table.insert(parts, text(rest, kind, size)) end
    local g = HorizontalGroup:new{ align = "center" }
    for _, p in ipairs(parts) do table.insert(g, p) end
    return g
end

--[[ Tap targets: a widget that remembers where it was drawn, so taps can be matched to it. ]]
local Target = WidgetContainer:extend{
    callback = nil,      -- a tap (or a longer press)
    hold_callback = nil, -- a finger held on it, when that does something else
    inverted = false,
}

function Target:getSize()
    return self[1]:getSize()
end

function Target:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1]:paintTo(bb, x, y)
    if self.inverted then
        bb:invertRect(x, y, size.w, size.h)
    end
end

--[[ The screen. ]]
local KitchenScreen = InputContainer:extend{
    name = "kitchen_screen",
    covers_fullscreen = true,       -- KOReader draws nothing underneath
    stop_events_propagation = true, -- every gesture stops here
    disable_double_tap = true,      -- a tap counts at once (no wait to see if a second one comes)
    -- ...and a second tap within half a second, in about the same place, doesn't count: a quick
    -- double tap would otherwise also press whatever the next screen has there (Next, a recipe).
    tap_interval_override = time.ms(500),
    data = nil,     -- from Data.load
    fonts = nil,    -- { title = ..., text = ... }: the handwriting fonts, as Font:getFace wants them
    on_admin = nil, -- function(screen): the menu for whoever looks after the Kobo
    on_sync = nil,  -- function(screen): "Get new recipes"
    on_close = nil, -- called once the screen has been closed
}

function KitchenScreen:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    S.W, S.H = W, H
    S.u = math.min(W / 1080, H / 1440)
    S.fonts = self.fonts
    S.plain_font = self.data and self.data.plain_font
    S.M = px(40) -- the margin all round
    S.text_size = (self.data and self.data.text_size) or 1
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = {
        KitchenTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        KitchenHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        KitchenSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    -- Keys (the Mac preview has a keyboard; the Aura HD has none) stop here too.
    if Device:hasKeys() then
        self.key_events = { KitchenKey = { { Device.input.group.Any } } }
    end
    -- When a message or menu is on top, a gesture it doesn't use goes down to the windows
    -- underneath; this stops it at the kitchen, before KOReader's own (its screenshot swipe).
    self.active_widgets = { InputContainer:new{ onGesture = function() return true end } }
    self.state = { screen = "home" }
    -- Only build here: UIManager:show(screen, "full") draws it the first time.
    self:render(nil, true)
end

-- Every gesture stops here: nothing underneath (KOReader's file browser) ever gets one.
function KitchenScreen:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end

function KitchenScreen:onKitchenKey() return true end

-- Newer KOReader closes the top window on a Home key: not this one.
function KitchenScreen:onHome() return true end

function KitchenScreen:onCloseWidget()
    if self.on_close then self.on_close() end
end

-- Going to sleep: a "Get new recipes" in the middle of connecting stops (sync.lua). And a
-- message that ignores taps for its first moment (its result) would turn touch back on 0.8 s
-- after it showed, under the sleep screen if the Kobo went to sleep straight away; a touch
-- there would close the sleep screen. KOReader turns touch back on itself when it wakes.
function KitchenScreen:onSuspend()
    local reenable = Device.input and Device.input._inhibitInputUntil_func
    if reenable then UIManager:unschedule(reenable) end
    if self.cancel_sync then self:safely(self.cancel_sync) end
end

-- Runs fn, and only logs it if something goes wrong: a mistake must never take KOReader down
-- (it would restart, and land back here, but the cook would see it happen).
function KitchenScreen:safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logger.err("kitchen:", err) end
    return ok
end

function KitchenScreen:go(state, refresh)
    self.state = state
    self:render(refresh)
end

function KitchenScreen:admin()
    if self.on_admin then self.on_admin(self) end
end

function KitchenScreen:addTarget(widget, callback, hold_callback)
    local t = Target:new{ widget, callback = callback, hold_callback = hold_callback }
    table.insert(self.targets, t)
    return t
end

-- The target under a finger, or else the nearest one within a finger's width. Only targets
-- that have been drawn count (a new screen's are drawn straight after it is built), and only
-- those `wanted` says (a tap only looks for things a tap does something to).
function KitchenScreen:targetAt(pos, wanted)
    local best, best_d
    local slop = px(30)
    for i = #self.targets, 1, -1 do
        local t = self.targets[i]
        local r = t.dimen
        if r and (not wanted or wanted(t)) then
            local dx = math.max(r.x - pos.x, 0, pos.x - (r.x + r.w))
            local dy = math.max(r.y - pos.y, 0, pos.y - (r.y + r.h))
            if dx == 0 and dy == 0 then return t end
            local d = math.max(dx, dy)
            if d <= slop and (not best_d or d < best_d) then best, best_d = t, d end
        end
    end
    return best
end

function KitchenScreen:onKitchenTap(_, ges)
    if self.busy or not (ges and ges.pos) then return true end
    local t = self:targetAt(ges.pos, function(x) return x.callback ~= nil end)
    if t then self:press(t) end
    return true
end

-- A finger held still: the admin menu on a big title; on anything else, the same as a tap.
function KitchenScreen:onKitchenHold(_, ges)
    if self.busy or not (ges and ges.pos) then return true end
    local t = self:targetAt(ges.pos)
    if t and t.hold_callback then
        self:safely(t.hold_callback)
    elseif t and t.callback then
        self:press(t)
    end
    return true
end

function KitchenScreen:onKitchenSwipe(_, ges)
    if self.busy or not ges then return true end
    if ges.direction == "west" and self.on_next then
        self:safely(self.on_next)
    elseif ges.direction == "east" and self.on_prev then
        self:safely(self.on_prev)
    end
    return true
end

-- Shows the press at once (the e-ink takes a moment to draw the next screen), then acts.
function KitchenScreen:press(t)
    if t.dimen then
        t.inverted = true
        UIManager:setDirty(self, function() return "fast", t.dimen end)
        UIManager:forceRePaint()
        t.inverted = false
    end
    local before = self.renders
    UIManager:nextTick(function()
        self:safely(t.callback)
        if self.renders == before and t.dimen and UIManager:isWidgetShown(self) then
            -- the screen didn't change (a message opened instead): take the highlight off
            UIManager:setDirty(self, function() return "ui", t.dimen end)
        end
    end)
end

--[[ Building blocks shared by the screens. ]]

-- A button with words: a rounded box of w x h.
function KitchenScreen:button(label, w, h, callback, opts)
    opts = opts or {}
    local size = opts.size or px(54)
    local border = opts.border or (opts.quiet and px(4) or px(6))
    local inner = w - 2 * border - px(24)
    local f = frame(w, h, fittedText(label, "title", size, inner, math.floor(size * 0.6)), {
        border = border,
        radius = opts.radius or px(30),
    })
    return self:addTarget(f, callback)
end

-- The bar at the top: a button on the left, and something on the right.
function KitchenScreen:topBar(left, right)
    local h = px(150)
    local g = OverlapGroup:new{ dimen = Geom:new{ w = S.W - 2 * S.M, h = h } }
    if left then
        table.insert(g, box(left:getSize().w, h, left))
    end
    if right then
        local r = box(right:getSize().w, h, right)
        r.overlap_align = "right"
        table.insert(g, r)
    end
    return g, h
end

-- The bar at the bottom: [left]   middle words   [right]. Missing buttons leave a gap.
function KitchenScreen:bottomBar(left, middle, right)
    local h = px(190)
    local w = S.W - 2 * S.M
    local g = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h } }
    if middle then
        table.insert(g, box(w, h, text(middle, "text", px(38))))
    end
    if left then
        table.insert(g, box(left:getSize().w, h, left))
    end
    if right then
        local r = box(right:getSize().w, h, right)
        r.overlap_align = "right"
        table.insert(g, r)
    end
    return g, h
end

-- A screen made of a top part and (optionally) a bar pinned to the bottom.
function KitchenScreen:layout(top, bottom, bottom_h)
    local page = OverlapGroup:new{ dimen = Geom:new{ w = S.W, h = S.H } }
    local t = HorizontalGroup:new{ hspan(S.M), top }
    t.overlap_offset = { 0, S.M }
    table.insert(page, t)
    if bottom then
        local b = HorizontalGroup:new{ hspan(S.M), bottom }
        b.overlap_offset = { 0, S.H - S.M - bottom_h }
        table.insert(page, b)
    end
    return page
end

-- Splits a list of blocks (widgets) into pages that fit `height`. A heading never ends a page.
local function paginate(blocks, height)
    local pages, page, used = {}, {}, 0
    for i, b in ipairs(blocks) do
        local h = b.widget:getSize().h + (b.space or 0)
        -- what has to come along: the headings straight after this one, and the first real block
        local keep, j = 0, i + 1
        while b.heading and blocks[j] do
            keep = keep + blocks[j].widget:getSize().h + (blocks[j].space or 0)
            if not blocks[j].heading then break end
            j = j + 1
        end
        if #page > 0 and (used + h > height or (b.heading and used + h + keep > height)) then
            table.insert(pages, page)
            page, used = {}, 0
        end
        table.insert(page, b)
        used = used + h
    end
    if #page > 0 then table.insert(pages, page) end
    return pages
end

--[[ The screens. ]]

-- Builds the current screen; then (unless build_only) asks for it to be drawn. Screens change
-- with a partial refresh (KOReader makes every sixth one a full flash, which clears the faint
-- ghosts e-ink keeps), and going back to the Recipe box always flashes clean.
function KitchenScreen:render(refresh, build_only)
    self.targets = {}
    self.on_next, self.on_prev = nil, nil
    local s = self.state
    local build = self["screen_" .. s.screen] or self.screen_home
    local ok, body = pcall(build, self, s)
    if not ok then
        logger.err("kitchen: couldn't draw", s.screen, body)
        self.state = { screen = "home" }
        self.targets = {}
        self.on_next, self.on_prev = nil, nil
        ok, body = pcall(self.screen_home, self, self.state)
        if not ok then
            logger.err("kitchen: couldn't draw the Recipe box", body)
            self.targets = {}
            body = self:screen_trouble()
        end
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = WHITE,
        width = S.W, height = S.H,
        body,
    }
    self.renders = (self.renders or 0) + 1
    if build_only then return end
    UIManager:setDirty(self, refresh or "partial")
end

-- Only if the recipes can't be drawn at all: a plain message (in KOReader's own font), and the
-- admin menu on a finger held on it.
function KitchenScreen:screen_trouble()
    local msg = TextBoxWidget:new{
        text = "Something went wrong showing the recipes.\n\nPlease tell whoever looks after the Kobo.",
        face = Font:getFace("cfont", 24),
        width = S.W - 4 * S.M,
        alignment = "center",
    }
    local t = self:addTarget(msg, nil, function() self:admin() end)
    return CenterContainer:new{ dimen = Geom:new{ w = S.W, h = S.H }, t }
end

-- Home: the Recipe box.
function KitchenScreen:screen_home()
    local d = self.data
    local w = S.W - 2 * S.M
    -- the title (a finger held on it opens the menu for whoever looks after the Kobo)
    local title = self:addTarget(fittedText(d.title, "title", px(112), w, px(72)), nil, function() self:admin() end)
    local items = { box(w, title:getSize().h, title) }
    local wave = image(Data.art(d, "wave"), px(560), px(36))
    if wave then table.insert(items, box(w, wave:getSize().h, wave)) end
    -- the tagline ("{count}" in it is the number of recipes)
    local tag = (d.tagline ~= "" and d.tagline or "{count} recipes"):gsub("{count}", tostring(d.count))
    local tag_text = text(tag, "text", px(42), w)
    table.insert(items, vspan(px(12)))
    table.insert(items, box(w, tag_text:getSize().h, tag_text))
    table.insert(items, vspan(px(34)))
    local top_h = 0
    for _, it in ipairs(items) do top_h = top_h + it:getSize().h end

    -- the tiles: every chapter, then A to Z and How it works
    local tiles = {}
    for _, ch in ipairs(d.chapters) do
        local n = #ch.recipes
        table.insert(tiles, {
            label = ch.short, sub = string.format(n == 1 and "%d recipe" or "%d recipes", n),
            pic = Data.art(d, ch.doodle) or Data.art(d, "heart"),
            go = function() self:go({ screen = "chapter", chapter = ch.id, page = 1 }) end,
        })
    end
    table.insert(tiles, { label = "A to Z", sub = "every recipe", pic = Data.art(d, "tile-az"),
        go = function() self:go({ screen = "letters" }) end })
    local how = { label = "How it works", sub = d.bundle_url and "and new recipes" or "the basics",
        bar = d.bundle_url and "How it works & new recipes" or "How it works",
        pic = Data.art(d, "tile-how"), go = function() self:go({ screen = "how" }) end }
    -- With 8 chapters, they and A to Z fill the 3x3 grid exactly, so How it works becomes a slim
    -- bar under it: the tiles stay nearly as big as with 7 (a fourth row, or four narrower
    -- columns, would squeeze them and the words on them). Any other number: a tile.
    local how_bar_h = (#tiles == 9) and px(110) or 0
    if how_bar_h == 0 then table.insert(tiles, how) end

    local footer = d.footer ~= "" and withHeart(d.footer, "title", px(42), Data.art(d, "heart")) or nil
    local footer_h = footer and footer:getSize().h or 0
    local avail = S.H - 2 * S.M - top_h - (footer and footer_h + px(20) or 0)
    local cols = (#tiles <= 9) and 3 or 4
    local gap = px(24)
    if how_bar_h > 0 then avail = avail - how_bar_h - gap end
    local rows = math.ceil(#tiles / cols)
    local tile_w = math.floor((w - (cols - 1) * gap) / cols)
    local tile_h = math.min(px(340), math.floor((avail - (rows - 1) * gap) / rows))
    -- the picture: half the tile, but no more than the words under it leave room for (the A to Z
    -- and How pictures have white backgrounds, which would cover the tile's edge)
    local m1, m2 = text("A to Z", "title", px(54)), text("every recipe", "text", px(32))
    local words_h = m1:getSize().h + m2:getSize().h
    m1:free()
    m2:free()
    local pic_size = math.floor(math.min(tile_w, tile_h) * 0.5)
    pic_size = math.max(px(60), math.min(pic_size, tile_h - 2 * px(5) - px(6) - words_h - px(14)))
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for col = 1, cols do
            local tile = tiles[(r - 1) * cols + col]
            if col > 1 then table.insert(row, hspan(gap)) end
            if tile then
                local inside = {}
                local pic = image(tile.pic, pic_size, pic_size)
                if pic then table.insert(inside, pic) end
                table.insert(inside, vspan(px(6)))
                table.insert(inside, fittedText(tile.label, "title", px(54), tile_w - px(30), px(36)))
                table.insert(inside, text(tile.sub, "text", px(32), tile_w - px(30)))
                table.insert(row, self:addTarget(frame(tile_w, tile_h, vgroup(inside, "center"), { border = px(5), radius = px(30) }), tile.go))
            end
        end
        if r > 1 then table.insert(items, vspan(gap)) end
        table.insert(items, row)
    end
    if how_bar_h > 0 then
        -- made last, so the tiles stay the first things to tap on this screen
        local pic_h = how_bar_h - px(34)
        local inside = HorizontalGroup:new{ align = "center" }
        local pic = image(how.pic, pic_h, pic_h)
        if pic then
            table.insert(inside, pic)
            table.insert(inside, hspan(px(20)))
        end
        table.insert(inside, fittedText(how.bar, "title", px(50), w - pic_h - px(80), px(34)))
        table.insert(items, vspan(gap))
        table.insert(items, self:addTarget(frame(w, how_bar_h, inside, { border = px(5), radius = px(30) }), how.go))
    end
    local bottom = footer and box(w, footer_h, footer) or nil
    return self:layout(vgroup(items), bottom, footer_h)
end

-- A list of recipes as big buttons, in pages: a chapter, or the recipes under one letter.
function KitchenScreen:recipeList(s, title, sub, slugs, back_label, back, pic_path)
    local w = S.W - 2 * S.M
    local back_btn = self:button(back_label, px(440), px(130), back, { quiet = true })
    local pic = image(pic_path, px(120), px(120))
    local bar = self:topBar(back_btn, pic)
    local head_items = {
        bar, vspan(px(10)),
        textBox(title, "title", px(80), w, "left", 0.05),
        text(sub, "text", px(38), w),
        vspan(px(24)),
    }
    local head_h = 0
    for _, it in ipairs(head_items) do head_h = head_h + it:getSize().h end

    local min_row, gap = px(124), px(18)
    local bottom_h = px(190)
    local avail = S.H - 2 * S.M - head_h
    local per_page = math.max(1, math.floor((avail + gap) / (min_row + gap)))
    local pages = 1
    if #slugs > per_page then
        avail = avail - bottom_h - px(20)
        per_page = math.max(1, math.floor((avail + gap) / (min_row + gap)))
        pages = math.ceil(#slugs / per_page)
    end
    -- the rows share out the room there is (bigger buttons), up to a point
    local row_h = math.max(min_row, math.min(px(170), math.floor((avail + gap) / per_page) - gap))
    local page = math.max(1, math.min(s.page or 1, pages))
    local function at(p)
        return { screen = s.screen, chapter = s.chapter, letter = s.letter, page = p }
    end
    local here = at(page)
    local inner_w, inner_h = w - 2 * px(4), row_h - 2 * px(4)
    for i = (page - 1) * per_page + 1, math.min(#slugs, page * per_page) do
        local slug = slugs[i]
        local r = self.data.recipes[slug]
        local name = fittedText(r.title, "title", px(56), w - px(120), px(40))
        local row = OverlapGroup:new{ dimen = Geom:new{ w = inner_w, h = inner_h },
            box(inner_w, inner_h, HorizontalGroup:new{ hspan(px(26)), name }, "left") }
        local arrow = box(px(70), inner_h, text("›", "title", px(64)))
        arrow.overlap_align = "right"
        table.insert(row, arrow)
        local f = FrameContainer:new{ bordersize = px(4), radius = px(26), padding = 0, margin = 0, background = WHITE, color = BLACK, row }
        if i > (page - 1) * per_page + 1 then table.insert(head_items, vspan(gap)) end
        table.insert(head_items, self:addTarget(f, function()
            self:go({ screen = "recipe", recipe = slug, page = 1, from = here })
        end))
    end
    local bottom
    if pages > 1 then
        local prev = page > 1 and self:button("‹ Back", px(400), px(150), function() self:go(at(page - 1)) end) or nil
        local nxt = page < pages and self:button("More ›", px(400), px(150), function() self:go(at(page + 1)) end) or nil
        bottom = self:bottomBar(prev, string.format("%d of %d", page, pages), nxt)
        if page < pages then self.on_next = function() self:go(at(page + 1)) end end
        if page > 1 then self.on_prev = function() self:go(at(page - 1)) end end
    end
    return self:layout(vgroup(head_items), bottom, bottom_h)
end

function KitchenScreen:screen_chapter(s)
    local ch = self.data.chapter_by_id[s.chapter]
    if not ch then return self:screen_home() end
    local n = #ch.recipes
    return self:recipeList(s, ch.name, string.format(n == 1 and "%d recipe" or "%d recipes", n), ch.recipes,
        "‹ Recipe box", function() self:go({ screen = "home" }, "full") end,
        Data.art(self.data, ch.doodle))
end

function KitchenScreen:screen_letters()
    local d = self.data
    local w = S.W - 2 * S.M
    local back_btn = self:button("‹ Recipe box", px(440), px(130), function() self:go({ screen = "home" }, "full") end, { quiet = true })
    local bar = self:topBar(back_btn, image(Data.art(d, "tile-az"), px(120), px(120)))
    local items = { bar, vspan(px(10)),
        text("A to Z", "title", px(80), w),
        text(string.format("all %d recipes, by their first letter", d.count), "text", px(38), w),
        vspan(px(24)),
    }
    local head_h = 0
    for _, it in ipairs(items) do head_h = head_h + it:getSize().h end
    local cols, gap = 4, px(22)
    local cell_w = math.floor((w - (cols - 1) * gap) / cols)
    local avail = S.H - 2 * S.M - head_h
    local rows = math.ceil(#d.letters / cols)
    local cell_h = math.min(px(190), math.floor((avail - (rows - 1) * gap) / rows))
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for col = 1, cols do
            local L = d.letters[(r - 1) * cols + col]
            if col > 1 then table.insert(row, hspan(gap)) end
            if L then
                local slugs = d.by_letter[L]
                -- a letter with one recipe names it, and opens it straight away
                local sub = (#slugs == 1) and d.recipes[slugs[1]].title or string.format("%d recipes", #slugs)
                local inside = vgroup({
                    text(L, "title", px(84)),
                    fittedText(sub, "text", px(30), cell_w - px(20), px(22)),
                }, "center")
                table.insert(row, self:addTarget(frame(cell_w, cell_h, inside, { border = px(5), radius = px(26) }), function()
                    if #slugs == 1 then
                        self:go({ screen = "recipe", recipe = slugs[1], page = 1, from = { screen = "letters" } })
                    else
                        self:go({ screen = "letter", letter = L, page = 1 })
                    end
                end))
            end
        end
        if r > 1 then table.insert(items, vspan(gap)) end
        table.insert(items, row)
    end
    return self:layout(vgroup(items))
end

function KitchenScreen:screen_letter(s)
    local slugs = self.data.by_letter[s.letter]
    if not slugs then return self:screen_letters() end
    return self:recipeList(s, s.letter, string.format("%d recipes", #slugs), slugs,
        "‹ A to Z", function() self:go({ screen = "letters" }) end, Data.art(self.data, "tile-az"))
end

-- Where the recipe's "‹" button goes: back to the list it was opened from.
function KitchenScreen:backFrom(s, r)
    local from = s.from
    if from and from.screen == "letter" then
        return "‹ " .. from.letter, from
    elseif from and from.screen == "letters" then
        return "‹ A to Z", from
    end
    local ch = self.data.chapter_by_id[r.chapter]
    if ch then
        -- the chapter page that lists this recipe
        local page = (from and from.screen == "chapter" and from.chapter == ch.id and from.page) or 1
        return "‹ " .. ch.short, { screen = "chapter", chapter = ch.id, page = page }
    end
    return "‹ Recipe box", { screen = "home" }
end

-- The recipe as a list of blocks (widgets) to share out over pages. A block may carry the
-- button inside it (`target`), which can only be tapped while its block is on screen.
function KitchenScreen:recipeBlocks(r, s)
    local w = S.W - 2 * S.M
    local ts = S.text_size
    local blocks = {}
    local function add(widget, space, heading, target)
        table.insert(blocks, { widget = widget, space = space or 0, heading = heading, target = target })
    end
    local function startButton(space)
        local b = self:button("Start cooking ›", px(640), px(140), function()
            self:go({ screen = "cook", recipe = r.slug, step = 1, from = s })
        end)
        add(box(w, px(140), b), space, false, b)
    end

    add(textBox(r.title, "title", px(84), w, "left", 0.05))
    if r.aka ~= "" then add(textBox(r.aka, "text", px(38), w), px(4)) end
    local wave = image(Data.art(self.data, "wave"), px(520), px(34))
    if wave then add(wave, px(8)) end
    local can_cook = self.data.cooking and #r.steps > 0
    if can_cook then startButton(px(24)) end

    local multi = #r.sections > 1
    local function heading(str)
        add(vgroup({ text(str, "title", px(60)), line(w, px(4), BLACK) }), px(30), true)
    end
    local function subheading(str)
        add(text(str, "title", math.floor(px(46) * ts), w), px(18), true)
    end

    local any_ingredients, any_steps = false, false
    for _, sec in ipairs(r.sections) do
        if #sec.ingredients > 0 then any_ingredients = true end
        if #sec.steps > 0 then any_steps = true end
    end
    if any_ingredients then
        heading("What you need")
        local amount_size = math.floor(px(46) * ts)
        for _, sec in ipairs(r.sections) do
            if #sec.ingredients > 0 then
                if multi and sec.heading ~= "" then subheading(sec.heading) end
                -- a column for the amounts (in the handwriting), as wide as this part's widest
                -- one needs; none at all when this part gives no amounts
                local amount_w = 0
                for _, i in ipairs(sec.ingredients) do
                    if i.amount ~= "" then
                        local t = text(i.amount, "title", amount_size)
                        amount_w = math.max(amount_w, t:getSize().w)
                        t:free()
                    end
                end
                amount_w = math.min(amount_w, px(300))
                for _, i in ipairs(sec.ingredients) do
                    local row = HorizontalGroup:new{ align = "top" }
                    local text_w = w
                    if amount_w > 0 then
                        table.insert(row, TextBoxWidget:new{ text = i.amount, face = face("title", amount_size), width = amount_w,
                            fgcolor = BLACK, line_height = 0.1 })
                        table.insert(row, hspan(px(20)))
                        text_w = w - amount_w - px(20)
                    end
                    table.insert(row, textBox(i.text, "text", math.floor(px(44) * ts), text_w))
                    add(vgroup({ vspan(px(8)), row, vspan(px(8)), line(w, px(2)) }))
                end
            end
        end
    end

    if any_steps then
        heading("How to make it")
        for _, sec in ipairs(r.sections) do
            if #sec.steps > 0 then
                if multi and sec.heading ~= "" then subheading(sec.heading) end
                for k, step in ipairs(sec.steps) do
                    local badge = frame(px(72), px(72), text(tostring(k), "title", px(42)), { border = px(4), radius = px(36) })
                    local row = HorizontalGroup:new{ align = "top", badge, hspan(px(22)),
                        textBox(step, "text", math.floor(px(44) * ts), w - px(94)) }
                    add(vgroup({ vspan(px(12)), row, vspan(px(12)), line(w, px(2)) }))
                end
            end
        end
    end

    local heart = Data.art(self.data, "heart")
    for _, n in ipairs(r.notes) do
        local tag = HorizontalGroup:new{ align = "center", text("note ", "title", px(42)) }
        local h = image(heart, px(34), px(34))
        if h then table.insert(tag, h) end
        add(FrameContainer:new{ bordersize = px(4), radius = px(28), padding = px(26), margin = 0, background = WHITE, color = BLACK,
            vgroup({ tag, textBox(n, "text", math.floor(px(42) * ts), w - px(70)) }) }, px(26))
    end
    if r.gap ~= "" then
        add(FrameContainer:new{ bordersize = px(2), radius = px(20), padding = px(22), margin = 0, background = WHITE, color = BLACK,
            textBox(r.gap, "text", math.floor(px(38) * ts), w - px(50)) }, px(26))
    end
    local blob = { r.title, r.aka, r.gap, table.concat(r.notes, " ") }
    for _, sec in ipairs(r.sections) do
        for _, i in ipairs(sec.ingredients) do table.insert(blob, i.amount .. " " .. i.text) end
        table.insert(blob, table.concat(sec.steps, " "))
    end
    if table.concat(blob, " "):find("(?)", 1, true) then
        add(textBox("(?) means the original was hard to read there.", "text", px(34), w), px(22))
    end
    if can_cook and #blocks > 8 then startButton(px(30)) end
    return blocks
end

function KitchenScreen:screen_recipe(s)
    local r = self.data.recipes[s.recipe]
    if not r then return self:screen_home() end
    local back_label, back_state = self:backFrom(s, r)
    local bar_targets = {}
    local back = self:button(back_label, px(440), px(130), function() self:go(back_state) end, { quiet = true })
    local home = self:button("Recipe box", px(360), px(130), function() self:go({ screen = "home" }, "full") end, { quiet = true })
    bar_targets[back], bar_targets[home] = true, true
    local bar, bar_h = self:topBar(back, home)
    local bottom_h = px(190)
    local avail_one = S.H - 2 * S.M - bar_h - px(16)

    local blocks = self:recipeBlocks(r, s)
    local pages = paginate(blocks, avail_one)
    if #pages > 1 then pages = paginate(blocks, avail_one - bottom_h - px(10)) end
    local page = math.max(1, math.min(s.page or 1, #pages))
    -- Only the buttons on this page can be tapped; the blocks on other pages are let go.
    local shown = {}
    for _, b in ipairs(pages[page]) do
        shown[b] = true
        if b.target then bar_targets[b.target] = true end
    end
    local keep = {}
    for _, t in ipairs(self.targets) do
        if bar_targets[t] then table.insert(keep, t) end
    end
    self.targets = keep
    for _, b in ipairs(blocks) do
        if not shown[b] and b.widget.free then b.widget:free() end
    end

    local items = { bar, vspan(px(16)) }
    for i, b in ipairs(pages[page]) do
        if i > 1 and b.space > 0 then table.insert(items, vspan(b.space)) end
        table.insert(items, b.widget)
    end
    local bottom
    if #pages > 1 then
        local function turn(p)
            return function() self:go({ screen = "recipe", recipe = s.recipe, page = p, from = s.from }) end
        end
        local prev = page > 1 and self:button("‹ Back", px(400), px(150), turn(page - 1)) or nil
        local nxt = page < #pages and self:button("Next ›", px(400), px(150), turn(page + 1)) or nil
        bottom = self:bottomBar(prev, string.format("page %d of %d", page, #pages), nxt)
        if page < #pages then self.on_next = turn(page + 1) end
        if page > 1 then self.on_prev = turn(page - 1) end
    end
    return self:layout(vgroup(items), bottom, bottom_h)
end

-- Cooking mode: one step per screen.
function KitchenScreen:screen_cook(s)
    local r = self.data.recipes[s.recipe]
    if not r or #r.steps == 0 then return self:screen_home() end
    local k = math.max(1, math.min(s.step or 1, #r.steps))
    local step = r.steps[k]
    local w = S.W - 2 * S.M
    -- "‹ Recipe" goes back to the recipe page cooking was started from
    local recipe_state = (s.from and s.from.screen == "recipe") and s.from or { screen = "recipe", recipe = r.slug, page = 1 }
    local function toStep(n)
        return function() self:go({ screen = "cook", recipe = r.slug, step = n, from = s.from }) end
    end
    local function done() self:go({ screen = "done", recipe = r.slug, from = recipe_state }) end

    local back = self:button("‹ Recipe", px(400), px(130), function() self:go(recipe_state) end, { quiet = true })
    local where = vgroup({
        fittedText(r.title, "title", px(46), w - px(460), px(32)),
        text(string.format("step %d of %d", k, #r.steps), "text", px(38)),
    }, "right")
    local bar = self:topBar(back, where)

    local prev
    if k == 1 then
        prev = self:button("‹ Recipe", px(470), px(170), function() self:go(recipe_state) end)
        self.on_prev = function() self:go(recipe_state) end
    else
        prev = self:button("‹ Back", px(470), px(170), toStep(k - 1))
        self.on_prev = toStep(k - 1)
    end
    local nxt
    if k < #r.steps then
        nxt = self:button("Next ›", px(470), px(170), toStep(k + 1))
        self.on_next = toStep(k + 1)
    else
        nxt = self:button("All done!", px(470), px(170), done)
        self.on_next = done
    end
    local bottom, bottom_h = self:bottomBar(prev, nil, nxt)

    local items = { bar, vspan(px(24)) }
    if step.heading ~= "" then
        table.insert(items, text(step.heading, "title", px(60), w))
        table.insert(items, vspan(px(16)))
    end
    local used = 0
    for _, it in ipairs(items) do used = used + it:getSize().h end
    -- the step, as big as fits above the buttons
    local avail = S.H - 2 * S.M - used - bottom_h - px(30)
    local size = math.floor(px(80) * S.text_size)
    local badge_d = px(116)
    local body
    while true do
        body = textBox(step.text, "text", size, w - badge_d - px(34), "left", 0.25)
        if body:getSize().h <= avail or size <= px(40) then break end
        body:free()
        size = size - px(4)
    end
    local badge = frame(badge_d, badge_d, text(tostring(step.n), "title", px(70)), { border = px(5), radius = math.floor(badge_d / 2) })
    table.insert(items, HorizontalGroup:new{ align = "top", badge, hspan(px(34)), body })
    return self:layout(vgroup(items), bottom, bottom_h)
end

function KitchenScreen:screen_done(s)
    local r = self.data.recipes[s.recipe]
    if not r then return self:screen_home() end
    local w = S.W - 2 * S.M
    local recipe_state = s.from or { screen = "recipe", recipe = r.slug, page = 1 }
    -- the list the recipe was opened from (the same as the recipe's own "‹" button)
    local list_label, list_state = self:backFrom(recipe_state, r)
    local g = VerticalGroup:new{ align = "center",
        vspan(px(240)),
        withHeart("Enjoy! {heart}", "title", px(150), Data.art(self.data, "heart")),
        vspan(px(20)),
        textBox(r.title, "title", px(72), w, "center", 0.05),
        vspan(px(120)),
        HorizontalGroup:new{ align = "center",
            self:button("‹ Recipe", px(440), px(160), function() self:go(recipe_state) end),
            hspan(px(40)),
            self:button("Recipe box", px(440), px(160), function() self:go({ screen = "home" }, "full") end),
        },
    }
    if list_state.screen ~= "home" then
        table.insert(g, vspan(px(40)))
        table.insert(g, self:button(list_label, px(560), px(150), function() self:go(list_state) end, { quiet = true }))
    end
    return self:layout(box(w, g:getSize().h, g))
end

function KitchenScreen:screen_how()
    local d = self.data
    local w = S.W - 2 * S.M
    local back_btn = self:button("‹ Recipe box", px(440), px(130), function() self:go({ screen = "home" }, "full") end, { quiet = true })
    local bar = self:topBar(back_btn, image(Data.art(d, "tile-how"), px(120), px(120)))
    -- (a finger held on the title opens the menu for whoever looks after the Kobo)
    local title = self:addTarget(text("How it works", "title", px(80), w), nil, function() self:admin() end)
    local paras = {
        "Tap a picture, a name or a button to open it. Swipe left or right to turn a page.",
    }
    if d.cooking then
        table.insert(paras, "Start cooking shows one step at a time in big writing. Next and Back go from step to step.")
    end
    table.insert(paras, "The Kobo goes to sleep by itself. Use its power switch to wake it up: it's where you left it.")
    local edition = Data.longDate(d.latest.edition)
    table.insert(paras, edition and string.format("These are the recipes of %s (%d recipes).", edition, d.count)
        or string.format("There are %d recipes.", d.count))
    local g = VerticalGroup:new{ align = "left", bar, vspan(px(10)), title, vspan(px(20)) }
    for _, p in ipairs(paras) do
        table.insert(g, textBox(p, "text", px(44), w, "left", 0.25))
        table.insert(g, vspan(px(26)))
    end
    -- only when the recipes name a website to get new ones from (book.json's bundleUrl)
    if self.on_sync and d.bundle_url then
        table.insert(g, vspan(px(10)))
        table.insert(g, box(w, px(150), self:button("Get new recipes", px(620), px(150), function() self.on_sync(self) end)))
        table.insert(g, box(w, px(60), text("It needs Wi-Fi and takes about a minute.", "text", px(34))))
    end
    local footer = d.footer ~= "" and withHeart(d.footer, "title", px(42), Data.art(d, "heart")) or nil
    local bottom = footer and box(w, footer:getSize().h, footer) or nil
    return self:layout(g, bottom, bottom and bottom:getSize().h or 0)
end

-- New recipes arrived: start again from the Recipe box with them.
function KitchenScreen:setData(data)
    self.data = data
    S.plain_font = data.plain_font
    S.text_size = data.text_size or 1
    self:go({ screen = "home" }, "full")
end

-- While "Get new recipes" runs, taps and swipes do nothing.
function KitchenScreen:setBusy(busy)
    self.busy = busy
end

return KitchenScreen
