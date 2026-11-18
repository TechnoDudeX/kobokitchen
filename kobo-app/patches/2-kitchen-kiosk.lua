--[[
The kitchen recipe box: the settings KOReader reads before any plugin starts, put right at
every start.
(This file goes in KOReader's patches/ folder; KOReader runs it just before it opens anything.)

  - the first-run guide never opens (it would open as a book, before the kitchen does);
  - KOReader always starts in its file browser, which the kitchen then covers;
  - a magnet near the Kobo (on a fridge door!) doesn't put it to sleep;
  - KOReader switches the Kobo off only after 28 days asleep, the longest it offers, instead of
    its usual 3 (switched off, it would start up in Kobo's own software). Its automatic
    sleep-timer reads this as it starts, so it has to be set here, first.
  - KOReader's cover browser (pictures of books in its own file browser, which the kitchen
    covers) is off: it isn't needed, and it pops up a message the first time it starts.

Everything else the kitchen needs is set by the plugin itself (kitchen.koplugin/main.lua).
]]
local S = G_reader_settings
if not S then return end

local shown = S:readSetting("quickstart_shown_version")
if type(shown) ~= "number" or shown < 2021070000 then
    S:saveSetting("quickstart_shown_version", 202607010000)
end
if S:readSetting("start_with") ~= "filemanager" then
    S:saveSetting("start_with", "filemanager")
end

-- KOReader's own 3 days counts as "not chosen"; any other choice someone made in its menus stays.
local off_after = S:readSetting("autoshutdown_timeout_seconds")
if off_after == nil or off_after == 3 * 24 * 60 * 60 then
    S:saveSetting("autoshutdown_timeout_seconds", 28 * 24 * 60 * 60)
end

if S:readSetting("ignore_power_sleepcover") == nil then
    S:saveSetting("ignore_power_sleepcover", true)
end
-- KOReader reads that one even earlier (when it sets up its buttons, just before this file),
-- so also do now what it would have done: no sleep-cover handlers.
if S:isTrue("ignore_power_sleepcover") then
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.isKobo and Device:isKobo() then
        local UIManager = require("ui/uimanager")
        if UIManager.event_handlers then
            UIManager.event_handlers.SleepCoverClosed = nil
            UIManager.event_handlers.SleepCoverOpened = nil
        end
        Device.is_cover_closed = false
    end
end

local disabled = S:readSetting("plugins_disabled")
if type(disabled) ~= "table" then disabled = {} end
if disabled.coverbrowser == nil then
    disabled.coverbrowser = true
    S:saveSetting("plugins_disabled", disabled)
end
