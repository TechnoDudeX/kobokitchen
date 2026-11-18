--[[
The kitchen recipe box: a KOReader plugin that turns a Kobo into a recipe box for the kitchen.

It opens by itself when KOReader starts and covers the whole screen with its own big-button
screens (kitchen/ui.lua). The recipes come from a computer (tools/kitchen-bundle.mjs): by cable
(tools/kobo-install.mjs), or, only if a website for them is set up, over Wi-Fi with "Get new
recipes" (kitchen/sync.lua). They live in <KOReader's data folder>/kitchen/current
(kitchen/data.lua). The sleep screen is the book's cover.

For whoever looks after the Kobo: hold a finger on the big title (of the Recipe box, or of How
it works) for a small menu: connecting to a computer by cable (for when the Kobo only charges
there), Wi-Fi setup (only when Wi-Fi updates are set up), or leaving to KOReader until the Kobo
next sleeps (it comes back on waking). KOReader's menu (the tools icon) has "Kitchen recipe box"
to open it again.

Written for KOReader 2026.07, and kept working on newer ones.
]]
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
-- Our own modules are loaded now, while KOReader looks in this plugin's folder first.
local Data = require("kitchen/data")
local KitchenScreen = require("kitchen/ui")
local Sync = require("kitchen/sync")

local opened_once = false -- this file runs once per KOReader start, so: once per start

local Kitchen = WidgetContainer:extend{
    name = "kitchen",
    is_doc_only = false,
}

-- This plugin's folder, as KOReader found it: "plugins/kitchen.koplugin" on the Kobo (relative
-- to KOReader's own folder, where KOReader runs), a full path on a computer.
local function pluginDir(plugin)
    local dir = plugin and plugin.path
    if type(dir) ~= "string" or dir == "" then
        dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$") or "plugins/kitchen.koplugin"
    end
    return dir
end

local function fullPath(path)
    if path:sub(1, 1) == "/" then return path end
    return (lfs.currentdir() or ".") .. "/" .. (path:gsub("^%./", ""))
end

-- The handwriting fonts, named the way Font:getFace needs them. KOReader 2026.07 puts "./fonts/"
-- in front of every name (newer versions take a full path as it is), so a relative folder is
-- reached by going up out of fonts/ first. Only fonts that are really there are given; the
-- screens use KOReader's own fonts for any that aren't.
local FONT_FILES = { title = "GochiHand-Regular.ttf", text = "PatrickHand-Regular.ttf" }
local function fontNames(dir)
    local names = {}
    for kind, file in pairs(FONT_FILES) do
        local path = dir .. "/fonts/" .. file
        if lfs.attributes(fullPath(path), "mode") == "file" then
            if path:sub(1, 1) == "/" then
                names[kind] = path
            else
                names[kind] = "../" .. (path:gsub("^%./", ""))
            end
        end
    end
    return names
end

-- The settings the kitchen needs. The ones KOReader reads before any plugin starts (the
-- first-run guide, the sleep-cover sensor) are set by patches/2-kitchen-kiosk.lua as well.
local function applySettings(data)
    local S = G_reader_settings
    local changed = false
    local function set(key, value)
        if S:readSetting(key) ~= value then
            S:saveSetting(key, value)
            changed = true
        end
    end
    -- The sleep screen is the cookbook's cover, with no words over it. (If KOReader ever
    -- switches the Kobo off, it says "Powered off" over the cover, so it doesn't look asleep.)
    local cover = Data.art(data, "cover")
    if cover then
        set("screensaver_type", "document_cover")
        set("screensaver_document_cover", cover)
        set("screensaver_show_message", false)
        set("screensaver_hide_fallback_msg", false)
    end
    -- "Get new recipes" turns Wi-Fi on without asking and off again afterwards, and it never
    -- comes back on by itself.
    set("wifi_enable_action", "turn_on")
    set("wifi_disable_action", "turn_off")
    set("auto_restore_wifi", false)
    -- (How long it sleeps before switching off is the start-up patch's job: KOReader reads it
    -- before any plugin starts.)
    if changed then S:flush() end
end

-- Holding the power switch for 2 seconds would switch the Kobo off, and it would then start up
-- in Kobo's own software. Here the switch only puts it to sleep and wakes it. (Holding it for
-- about 20 seconds still forces the Kobo off.)
local function powerSwitchOnlySleeps()
    local handlers = UIManager.event_handlers
    if Device:isKobo() and handlers and handlers.PowerPress then
        handlers.PowerPress = function() end
    end
end

-- Opens the kitchen, and if anything goes wrong on the way, says so instead of taking
-- KOReader down (it would restart into the same mistake, over and over).
function Kitchen.openSafely(dir)
    local ok, err = pcall(Kitchen.open, dir)
    if not ok then
        logger.err("kitchen: couldn't open:", err)
        if Kitchen.screen and not UIManager:isWidgetShown(Kitchen.screen) then Kitchen.screen = nil end
        UIManager:show(InfoMessage:new{
            text = _("The recipe box couldn't start. Please tell whoever looks after the Kobo."),
        })
    end
end

function Kitchen:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    powerSwitchOnlySleeps()
    if not opened_once then
        opened_once = true
        local dir = pluginDir(self)
        -- On the next tick, which KOReader runs before it draws anything: its file browser never
        -- shows. (If KOReader was set to open a book, the kitchen opens over that instead.)
        UIManager:nextTick(function() Kitchen.openSafely(dir) end)
    end
end

-- Waking up with the kitchen closed (someone left it to KOReader): it comes back. Not over a
-- book someone opened in KOReader. Whatever KOReader still had open above its file browser
-- (a menu, a dialog, its on-screen keyboard) is closed first: left on top, its keyboard would
-- cover the kitchen's buttons and the kitchen would get no taps. Each is asked to close itself
-- (so it tidies up after itself), then closed for sure.
function Kitchen:onResume()
    if not Kitchen.screen and not (self.ui and self.ui.document) then
        local dir, ui = pluginDir(self), self.ui
        UIManager:nextTick(function()
            if Kitchen.screen then return end
            for _ = 1, 20 do
                local top = UIManager:getTopmostVisibleWidget()
                if not top or top == ui then break end
                pcall(top.handleEvent, top, Event:new("Close"))
                if UIManager:isWidgetShown(top) then UIManager:close(top) end
            end
            Kitchen.openSafely(dir)
        end)
    end
end

function Kitchen:addToMainMenu(menu_items)
    menu_items.kitchen_recipe_box = {
        text = _("Kitchen recipe box"),
        sorting_hint = "tools",
        callback = function() Kitchen.openSafely(pluginDir(self)) end,
    }
end

function Kitchen.open(dir)
    if Kitchen.screen then return end
    local recovered, rerr = pcall(Data.recover)
    if not recovered then logger.warn("kitchen: couldn't tidy the recipes folder:", rerr) end
    local data, why = Data.load()
    if not data then
        logger.warn("kitchen: no recipes:", why)
        UIManager:show(InfoMessage:new{
            text = _("The recipe box can't find its recipes.") .. "\n\n" .. tostring(why),
        })
        return
    end
    applySettings(data)
    Sync.plugin_dir = fullPath(dir)
    Kitchen.screen = KitchenScreen:new{
        data = data,
        fonts = fontNames(dir),
        on_admin = function(screen) Kitchen.showAdmin(screen) end,
        -- (the screens only offer it when the recipes name a website: data.bundle_url)
        on_sync = function(screen) Sync.getNewRecipes(screen, applySettings) end,
        on_close = function() Kitchen.screen = nil end,
    }
    UIManager:show(Kitchen.screen, "full")
end

-- Shares the Kobo's storage with the computer at the other end of the cable, even though the Kobo
-- didn't offer to. Older Kobos (the 2013 Aura HD among them) decide only once, a moment after the
-- cable goes in, whether they're on a computer or a charger, and some computers' own ports (a
-- USB-C MacBook's) fail that test: the Kobo then only charges, and KOReader never asks "Share
-- storage via USB?". This is KOReader's own "Start USB storage", which skips that test when the
-- cable is already in. (Choosing it with no cable in would wait for one, and the same test would
-- turn the computer's port away again, so it asks for the cable first.) The USB screen that
-- follows stays until the cable comes out, with no time limit and a power switch that does
-- nothing, so the question before it says that unplugging is the way back, even if the computer
-- never shows the Kobo (or it's on a charger).
function Kitchen.connectToComputer()
    local function say(text) UIManager:show(InfoMessage:new{ text = text }) end
    if not Device:canToggleMassStorage() then
        return say(_("This only works on the Kobo."))
    end
    local MassStorage = require("ui/elements/mass_storage")
    if not MassStorage:isEnabled() then
        return say(_("Sharing by cable is switched off in KOReader's settings (Device > USB mass storage)."))
    end
    if not Device.powerd:isCharging() then
        return say(_("Plug the Kobo into the computer first, then choose Connect to computer again."))
    end
    UIManager:show(ConfirmBox:new{
        text = _("Connect to the computer?") .. "\n\n" .. _("The Kobo shows a USB screen until you unplug it. If the computer asks to allow it, click Allow. If the Kobo doesn't show up there within a minute, just unplug it: the kitchen comes back."),
        ok_text = _("Connect"),
        ok_callback = function() MassStorage:start(false) end,
    })
end

-- The menu for whoever looks after the Kobo (a finger held on a big title).
function Kitchen.showAdmin(screen)
    local dialog
    local function choice(text, fn)
        return { { text = text, callback = function()
            UIManager:close(dialog)
            if fn then fn() end
        end } }
    end
    local buttons = { choice(_("Back to the recipes")) }
    -- KOReader's own list of networks: pick the home Wi-Fi and type its password, once. Only
    -- offered when the recipes name a website to get new ones from (book.json's bundleUrl).
    if screen and screen.data and screen.data.bundle_url then
        table.insert(buttons, choice(_("Wi-Fi setup"), function() NetworkMgr:toggleWifiOn(nil, true, true) end))
    end
    -- for when it only charges on the computer's cable
    table.insert(buttons, choice(_("Connect to computer"), Kitchen.connectToComputer))
    -- (it comes back when the Kobo next wakes up)
    table.insert(buttons, choice(_("Leave to KOReader until it sleeps"), function() UIManager:close(screen, "full") end))
    dialog = ButtonDialog:new{
        title = _("For whoever looks after the Kobo"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Kitchen
