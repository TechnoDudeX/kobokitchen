--[[
The kitchen recipe box's preview driver. tools/kitchen-preview.mjs copies it into a throwaway
KOReader profile on the Mac as patches/2-zz-kitchen-preview.lua; it never goes on the Kobo, and
does nothing unless KITCHEN_PREVIEW_OUT is set.

Once the kitchen is open, it goes through the screens (the ways in with real taps, holds and
swipes, the rest directly), saves a picture of each in $KITCHEN_PREVIEW_OUT, notes what happened
in preview-steps.txt there, and quits KOReader.

With KITCHEN_PREVIEW_SITE set (kitchen-preview.mjs --test-wifi), "Get new recipes" reads from
that folder instead of the internet: a stand-in website in three versions (newer, older,
bumped), each a bundle as tools/kitchen-bundle.mjs makes it.
]]
local out = os.getenv("KITCHEN_PREVIEW_OUT")
if not out or out == "" then return end

local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local time = require("ui/time")

local notes = {}
local function note(text)
    table.insert(notes, text)
    logger.info("kitchen-preview:", text)
end

local function finish(code)
    local f = io.open(out .. "/preview-steps.txt", "w")
    if f then
        f:write(table.concat(notes, "\n"), "\n")
        f:close()
    end
    UIManager:quit(code)
end

local function kitchen()
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.kitchen
    return plugin and plugin.screen
end

local function middle(t)
    local r = t and t.dimen
    if not r then return nil end
    return Geom:new{ x = r.x + math.floor(r.w / 2), y = r.y + math.floor(r.h / 2), w = 0, h = 0 }
end

local function gesture(ges)
    ges.time = time.now()
    UIManager:sendEvent(Event:new("Gesture", ges))
end

local function swipeLeft()
    gesture({ ges = "swipe", direction = "west", distance = 500, pos = Geom:new{ x = 540, y = 900, w = 0, h = 0 } })
end

-- Closes whatever is above the kitchen (a menu, a message).
local function closeTop(k)
    local top = UIManager:getTopmostVisibleWidget()
    if top and top ~= k then UIManager:close(top) end
end

-- Places worth a picture, found in the recipes themselves.
local function biggestChapter(d)
    local best
    for _, c in ipairs(d.chapters) do
        if not best or #c.recipes > #best.recipes then best = c end
    end
    return best
end

local function weight(r)
    local n = #r.steps * 3 + #r.notes * 4
    for _, s in ipairs(r.sections) do n = n + #s.ingredients end
    return n
end

local function recipeBy(d, better)
    local best
    for _, slug in ipairs(d.az) do
        local r = d.recipes[slug]
        if #r.steps > 0 and (not best or better(r, best)) then best = r end
    end
    return best
end

local function busiestLetter(d)
    local best
    for _, L in ipairs(d.letters) do
        if not best or #d.by_letter[L] > #d.by_letter[best] then best = L end
    end
    return best
end

local steps = {}
local function step(name, fn) table.insert(steps, { name = name, fn = fn }) end

step("home", function(k) k:go({ screen = "home" }, "full") end)
step("chapter-by-tap", function(k)
    k:go({ screen = "home" }, "full")
    UIManager:forceRePaint()
    for _, t in ipairs(k.targets) do
        if t.callback then
            gesture({ ges = "tap", pos = middle(t) })
            return "tapped the first tile"
        end
    end
    return "no tile to tap"
end)
step("chapter-biggest", function(k)
    local c = biggestChapter(k.data)
    k:go({ screen = "chapter", chapter = c.id, page = 1 })
    return c.name .. " (" .. #c.recipes .. " recipes)"
end)
step("chapter-page-2-by-swipe", function(k)
    UIManager:forceRePaint()
    if not k.on_next then return "only one page" end
    swipeLeft()
end)
step("letters", function(k) k:go({ screen = "letters" }) end)
step("letter-busiest", function(k)
    local L = busiestLetter(k.data)
    k:go({ screen = "letter", letter = L, page = 1 })
    return L
end)

-- The longest recipe, page by page, then cooking it.
local long
step("recipe-long-1", function(k)
    long = recipeBy(k.data, function(a, b) return weight(a) > weight(b) end)
    k:go({ screen = "recipe", recipe = long.slug, page = 1, from = { screen = "chapter", chapter = long.chapter, page = 1 } })
    return long.title
end)
for p = 2, 4 do
    step("recipe-long-" .. p .. "-by-swipe", function(k)
        UIManager:forceRePaint()
        if not k.on_next then return "no page " .. p end
        swipeLeft()
    end)
end
step("cook-step-1", function(k)
    k:go({ screen = "cook", recipe = long.slug, step = 1, from = { screen = "recipe", recipe = long.slug, page = 1 } })
end)
step("cook-step-2-by-tap", function(k)
    UIManager:forceRePaint()
    local t = k.targets[#k.targets] -- "Next ›" is the last button made
    if not t then return "no button" end
    gesture({ ges = "tap", pos = middle(t) })
end)
step("cook-longest-step", function(k)
    local best, n = 1, 0
    for i, s in ipairs(long.steps) do
        if #s.text > n then best, n = i, #s.text end
    end
    k:go({ screen = "cook", recipe = long.slug, step = best, from = { screen = "recipe", recipe = long.slug, page = 1 } })
    return "step " .. best .. " (" .. n .. " characters)"
end)
step("cook-last-step", function(k)
    k:go({ screen = "cook", recipe = long.slug, step = #long.steps, from = { screen = "recipe", recipe = long.slug, page = 1 } })
end)
step("done", function(k)
    k:go({ screen = "done", recipe = long.slug, from = { screen = "recipe", recipe = long.slug, page = 1 } })
end)
step("recipe-short", function(k)
    local short = recipeBy(k.data, function(a, b) return weight(a) < weight(b) end)
    k:go({ screen = "recipe", recipe = short.slug, page = 1 })
    return short.title
end)
-- A recipe asked for by name (kitchen-preview.mjs --recipe <slug>), both its pages.
local wanted = os.getenv("KITCHEN_PREVIEW_RECIPE")
if wanted and wanted ~= "" then
    step("recipe-" .. wanted, function(k)
        if not k.data.recipes[wanted] then return "there's no recipe " .. wanted end
        k:go({ screen = "recipe", recipe = wanted, page = 1 })
    end)
    step("recipe-" .. wanted .. "-2-by-swipe", function(k)
        UIManager:forceRePaint()
        if not k.on_next then return "only one page" end
        swipeLeft()
    end)
end
step("how-it-works", function(k) k:go({ screen = "how" }) end)
-- How it works is the last thing made on the Recipe box (a tile, or with 8 chapters a bar under
-- the grid): tapped for real.
step("how-it-works-by-tap", function(k)
    k:go({ screen = "home" }, "full")
    UIManager:forceRePaint()
    local t = k.targets[#k.targets]
    if not t then return "no button" end
    gesture({ ges = "tap", pos = middle(t) })
    return #k.data.chapters .. " chapters"
end)
-- Every chapter's first page, one picture each (titles and doodles, after chapters change),
-- before "Get new recipes" below, which can swap in the website's edition.
step("every-chapter", function(k, at)
    for n = #k.data.chapters, 1, -1 do
        local ch = k.data.chapters[n]
        table.insert(steps, at + 1, { name = "chapter-" .. ch.id, fn = function(k2)
            k2:go({ screen = "chapter", chapter = ch.id, page = 1 })
            return ch.name .. ", " .. #ch.recipes .. (#ch.recipes == 1 and " recipe" or " recipes")
        end })
    end
    k:go({ screen = "home" }, "full")
    return #k.data.chapters .. " chapters next"
end)
local function findButton(w, text, seen)
    if type(w) ~= "table" or seen[w] then return nil end
    seen[w] = true
    if w.text == text and w.callback and w.dimen then return w end
    for _, child in ipairs(w) do
        local b = findButton(child, text, seen)
        if b then return b end
    end
end
-- The menu for whoever looks after the Kobo: "Wi-Fi setup" is in it only when the recipes name
-- a website for Wi-Fi updates.
step("admin-menu-by-hold", function(k)
    k:go({ screen = "home" }, "full")
    UIManager:forceRePaint()
    gesture({ ges = "hold", pos = middle(k.targets[1]) })
    UIManager:forceRePaint()
    local top = UIManager:getTopmostVisibleWidget()
    if top == k then error("no menu opened") end
    local wifi = findButton(top, "Wi-Fi setup", {}) ~= nil
    if wifi ~= (k.data.bundle_url ~= nil) then
        error(wifi and "it offers Wi-Fi setup with no website set up" or "no Wi-Fi setup, though a website is set up")
    end
    return wifi and "with Wi-Fi setup" or "no Wi-Fi setup (no website set up)"
end)
step("admin-menu-closed", closeTop)
-- "Connect to computer" in that menu, tapped for real. On the Mac it can only say so; then the
-- preview plays a Kobo with no cable in, and one with the cable in, where it asks first and
-- KOReader's own "Start USB storage" is only noted (it would end KOReader).
local function tapButton(text)
    UIManager:forceRePaint()
    local b = findButton(UIManager:getTopmostVisibleWidget(), text, {})
    if not b then error("no " .. text .. " button on top") end
    gesture({ ges = "tap", pos = middle(b) })
end
local function holdTitleAndTap(k, text)
    closeTop(k)
    k:go({ screen = "home" }, "full")
    UIManager:forceRePaint()
    gesture({ ges = "hold", pos = middle(k.targets[1]) })
    tapButton(text)
end
local playing, started
local function playKobo(cable)
    local Device = require("device")
    local MassStorage = require("ui/elements/mass_storage")
    playing = playing or {
        can = rawget(Device, "canToggleMassStorage"),
        charging = rawget(Device.powerd, "isCharging"),
        start = rawget(MassStorage, "start"),
    }
    Device.canToggleMassStorage = function() return true end
    Device.powerd.isCharging = function() return cable end
    MassStorage.start = function(_, ask) started = { ask = ask } end
end
local function stopPlaying()
    if not playing then return end
    local Device = require("device")
    rawset(Device, "canToggleMassStorage", playing.can)
    rawset(Device.powerd, "isCharging", playing.charging)
    rawset(require("ui/elements/mass_storage"), "start", playing.start)
    playing = nil
end
step("connect-to-computer-on-the-mac", function(k) holdTitleAndTap(k, "Connect to computer") end)
step("connect-to-computer-no-cable", function(k)
    playKobo(false)
    started = nil
    holdTitleAndTap(k, "Connect to computer")
    if started then error("it started USB storage with no cable in") end
end)
step("connect-to-computer-cable-in", function(k)
    playKobo(true)
    started = nil
    holdTitleAndTap(k, "Connect to computer")
    if started then error("it started USB storage without asking first") end
    return "asks first"
end)
step("connect-to-computer-connect", function()
    local ok, err = pcall(tapButton, "Connect")
    stopPlaying()
    if not ok then error(err, 0) end
    if not started then error("it didn't start USB storage") end
    if started.ask ~= false then error("KOReader would ask again (ask = " .. tostring(started.ask) .. ")") end
    return "started KOReader's own USB storage, without asking again"
end)
step("long-diagonal-swipe-does-nothing", function(k)
    stopPlaying()
    closeTop(k)
    -- KOReader's screenshot gesture, if anything let it through
    gesture({ ges = "swipe", direction = "southeast", distance = 1750, pos = Geom:new{ x = 60, y = 60, w = 0, h = 0 } })
end)
-- "Get new recipes": what the cook sees, and how many recipes there are before and after.
local function getNewRecipes(k)
    closeTop(k)
    k:go({ screen = "how" })
    UIManager:forceRePaint()
    if not (k.on_sync and k.data.bundle_url) then return nil end
    local before = k.data.count
    k.on_sync(k)
    local top = UIManager:getTopmostVisibleWidget()
    local said = (top ~= k and top and type(top.text) == "string") and top.text or "(no message)"
    return string.format("%d -> %d recipes: %s", before, k.data.count, (said:gsub("%s*\n+%s*", " ")))
end
local site = os.getenv("KITCHEN_PREVIEW_SITE")
if site and site ~= "" then
    -- A stand-in website: the kitchen's own sync module reads the bundle from a folder on this
    -- Mac instead of over HTTPS. Everything after the download (the checks, the swap, the newer
    -- or older test, what the cook is told) is the real thing.
    local served
    local function useStandIn()
        local Sync = package.loaded["kitchen/sync"]
        if not Sync then error("the kitchen's sync module isn't loaded") end
        Sync.fetch = function(url)
            local path = url:match("^https://kitchen%-preview%.invalid/([^?#]*)")
            if not path or path == "" or path:find("..", 1, true) then return nil, "not the stand-in website: " .. url end
            local f = io.open(site .. "/" .. served .. "/" .. path, "rb")
            if not f then return nil, "the website answered 404" end
            local data = f:read("*a")
            f:close()
            return data
        end
    end
    local function website(version, want_count, want_said)
        return function(k)
            useStandIn()
            served = version
            local before = k.data.count
            local result = getNewRecipes(k)
            if not result then error("no Get new recipes on How it works") end
            local count = want_count == "same" and before or want_count
            if k.data.count ~= count then error(result .. " (wanted " .. count .. " recipes)") end
            if not result:find(want_said, 1, true) then error(result .. ' (wanted "' .. want_said .. '")') end
            return version .. " website: " .. result
        end
    end
    local all -- how many recipes the newer website has: one more than the Kobo starts with
    step("wifi-how-it-works", function(k)
        all = k.data.count + 1
        k:go({ screen = "how" })
    end)
    step("wifi-newer-website", function(k) return website("newer", all, "1 new: ")(k) end)
    step("wifi-older-website", function(k) return website("older", all, "newer than the website's")(k) end)
    step("wifi-same-website", function(k) return website("newer", all, "You already have the newest recipes")(k) end)
    step("wifi-bumped-website", function(k) return website("bumped", all - 1, "1 taken out: ")(k) end)
    step("wifi-message-closed", closeTop)
else
    -- The real website (book.json's bundleUrl), if there is one.
    step("get-new-recipes", function(k)
        return getNewRecipes(k) or "no Get new recipes (no website set up)"
    end)
    step("message-closed", closeTop)
end

local i = 0
local function nextStep()
    i = i + 1
    local s = steps[i]
    if not s then
        note("all done")
        return finish(0)
    end
    local k = kitchen()
    if not k then
        note("the kitchen isn't open")
        return finish(1)
    end
    local ok, said = pcall(s.fn, k, i)
    UIManager:scheduleIn(0.8, function()
        UIManager:forceRePaint()
        local file = string.format("%s/%02d-%s.png", out, i, s.name)
        local shot_ok = Screen:shot(file)
        local top = UIManager:getTopmostVisibleWidget()
        local on_top = (top == k) and "kitchen on top" or ("on top: " .. tostring(top and (top.name or top.title or "a dialog")))
        note(string.format("%02d %-32s %s%s; %s; %s", i, s.name,
            ok and "ok" or ("FAILED: " .. tostring(said)),
            (ok and said) and (" (" .. tostring(said) .. ")") or "",
            k.state.screen, on_top) .. (shot_ok == false and "; no picture" or ""))
        UIManager:scheduleIn(0.2, nextStep)
    end)
end

local waited = 0
local function start()
    if kitchen() then return nextStep() end
    waited = waited + 1
    if waited > 20 then
        note("the kitchen never opened")
        return finish(1)
    end
    UIManager:scheduleIn(0.5, start)
end

UIManager:scheduleIn(1, start)
UIManager:scheduleIn(200, function()
    note("gave up: it took too long")
    finish(2)
end)
