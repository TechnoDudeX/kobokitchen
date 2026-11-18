--[[
The kitchen recipe box: the recipes on the device.

They live in <KOReader's data folder>/kitchen/current/ (on the Kobo that is
/mnt/onboard/.adds/koreader/kitchen/current/), as made on the computer by
tools/kitchen-bundle.mjs:

    recipes.json   chapters, the A to Z order and every recipe, the words for the screens, and
                   (only if Wi-Fi updates are set up) the website to get new recipes from
    art/*.png      the doodles, the tiles and the cover
    latest.json    the edition's date and when it was built, how many recipes, and every file
                   with its size and SHA-256

The cable installer (tools/kobo-install.mjs) and "Get new recipes" (sync.lua) both build the
next edition in kitchen/new/ and swap it in: current -> old, new -> current, then remove old.
If the power goes in between, recover() puts things right on the next start.
]]
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local has_rapidjson, rapidjson = pcall(require, "rapidjson")
local json = (not has_rapidjson) and require("json") or nil

local Data = {
    FORMAT = 1, -- the recipes.json format this app understands
}

function Data.decodeJSON(text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, value
    if has_rapidjson then
        ok, value = pcall(rapidjson.decode, text)
    else
        ok, value = pcall(json.decode, text)
    end
    if ok and type(value) == "table" then return value end
    return nil
end

-- KOReader's data folder is "." on a Kobo (its own folder): always use the full path, so the
-- sleep screen setting and the files moved around in an update never depend on where we are.
function Data.root()
    local dir = DataStorage.getFullDataDir and DataStorage:getFullDataDir()
    if not dir then
        dir = DataStorage:getDataDir()
        if dir == "." then
            dir = lfs.currentdir() or "."
        elseif dir:sub(1, 1) ~= "/" then
            dir = (lfs.currentdir() or ".") .. "/" .. (dir:gsub("^%./", ""))
        end
    end
    return dir .. "/kitchen"
end

function Data.currentDir()
    return Data.root() .. "/current"
end

local function isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

function Data.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

-- Removes a folder and everything in it (only ever our own kitchen/new and kitchen/old).
function Data.removeTree(path)
    if not isDir(path) then
        if isFile(path) then os.remove(path) end
        return
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            Data.removeTree(path .. "/" .. name)
        end
    end
    lfs.rmdir(path)
end

-- Puts a swap that was cut off right: whichever complete edition is there becomes current.
function Data.recover()
    local root = Data.root()
    local cur, new, old = root .. "/current", root .. "/new", root .. "/old"
    if not isFile(cur .. "/recipes.json") then
        if isDir(cur) then Data.removeTree(cur) end
        if isFile(new .. "/latest.json") and isFile(new .. "/recipes.json") then
            os.rename(new, cur)
            logger.info("kitchen: finished installing the new recipes after a restart")
        elseif isFile(old .. "/recipes.json") then
            os.rename(old, cur)
            logger.info("kitchen: went back to the previous recipes after a restart")
        end
    end
    -- Leftovers of a finished or failed update.
    if isDir(old) and isFile(cur .. "/recipes.json") then Data.removeTree(old) end
end

local function nonEmptyString(v)
    return type(v) == "string" and v ~= ""
end

local function stringOr(v, default)
    if type(v) == "string" then return v end
    return default
end

local function list(v)
    if type(v) == "table" then return v end
    return {}
end

-- The website "Get new recipes" reads from (book.json's bundleUrl), always ending in "/", or nil
-- when there is none: then the kitchen offers no Wi-Fi at all. Only an https:// address counts.
function Data.bundleUrl(v)
    if type(v) ~= "string" or not v:match("^https://[%w%.%-]+[:%d]*/") or v:find("[%s?#]") then
        return nil
    end
    if v:sub(-1) ~= "/" then v = v .. "/" end
    return v
end

-- The first letter a recipe is filed under in A to Z: A-Z, or "#" for anything else.
function Data.letterOf(title)
    local c = (title or ""):match("^%s*(.)")
    c = c and c:upper() or "#"
    if not c:match("^%u$") then c = "#" end
    return c
end

-- Reads and checks a bundle folder. Returns the data, or nil and a reason.
-- Anything odd in a single recipe is tidied (missing text becomes empty), so one bad recipe
-- never takes the whole book down; only a broken file or the wrong format is refused.
function Data.load(dir)
    dir = dir or Data.currentDir()
    local d = Data.decodeJSON(Data.readFile(dir .. "/recipes.json"))
    if not d then return nil, "no readable recipes.json in " .. dir end
    if d.format ~= Data.FORMAT then
        return nil, "recipes.json is format " .. tostring(d.format) .. ", this app reads format " .. Data.FORMAT
    end
    local recipes = {}
    for slug, r in pairs(list(d.recipes)) do
        if type(slug) == "string" and type(r) == "table" and nonEmptyString(r.title) then
            local sections = {}
            for _, s in ipairs(list(r.sections)) do
                if type(s) == "table" then
                    local ingredients, steps = {}, {}
                    for _, i in ipairs(list(s.ingredients)) do
                        if type(i) == "table" and (nonEmptyString(i.text) or nonEmptyString(i.amount)) then
                            table.insert(ingredients, { amount = stringOr(i.amount, ""), text = stringOr(i.text, "") })
                        end
                    end
                    for _, x in ipairs(list(s.steps)) do
                        if nonEmptyString(x) then table.insert(steps, x) end
                    end
                    if #ingredients > 0 or #steps > 0 then
                        table.insert(sections, { heading = stringOr(s.heading, ""), ingredients = ingredients, steps = steps })
                    end
                end
            end
            local notes = {}
            for _, n in ipairs(list(r.notes)) do
                if nonEmptyString(n) then table.insert(notes, n) end
            end
            local steps = {}
            for _, s in ipairs(sections) do
                for k, x in ipairs(s.steps) do
                    table.insert(steps, { heading = (#sections > 1) and s.heading or "", text = x, n = k })
                end
            end
            recipes[slug] = {
                slug = slug,
                title = r.title,
                aka = stringOr(r.aka, ""),
                gap = stringOr(r.gap, ""),
                notes = notes,
                sections = sections,
                steps = steps, -- every step in order, for cooking mode
                chapter = stringOr(r.chapter, ""),
            }
        end
    end
    local chapters = {}
    for _, c in ipairs(list(d.chapters)) do
        if type(c) == "table" and nonEmptyString(c.id) and nonEmptyString(c.name) then
            local slugs = {}
            for _, s in ipairs(list(c.recipes)) do
                if recipes[s] then table.insert(slugs, s) end
            end
            if #slugs > 0 then
                table.insert(chapters, {
                    id = c.id, name = c.name, short = nonEmptyString(c.short) and c.short or c.name,
                    doodle = stringOr(c.doodle, "heart"), recipes = slugs,
                })
            end
        end
    end
    if #chapters == 0 then return nil, "recipes.json has no chapters" end
    local chapter_by_id = {}
    for _, c in ipairs(chapters) do chapter_by_id[c.id] = c end
    -- A to Z: the order the computer worked out (it sorts names properly), grouped by first letter.
    local az, seen = {}, {}
    for _, s in ipairs(list(d.az)) do
        if recipes[s] and not seen[s] then table.insert(az, s); seen[s] = true end
    end
    for _, c in ipairs(chapters) do
        for _, s in ipairs(c.recipes) do
            if not seen[s] then table.insert(az, s); seen[s] = true end
        end
    end
    local letters, by_letter = {}, {}
    for _, s in ipairs(az) do
        local L = Data.letterOf(recipes[s].title)
        if not by_letter[L] then
            by_letter[L] = {}
            table.insert(letters, L)
        end
        table.insert(by_letter[L], s)
    end
    local settings = type(d.settings) == "table" and d.settings or {}
    return {
        dir = dir,
        title = nonEmptyString(d.title) and d.title or "Recipe Box",
        tagline = stringOr(d.tagline, ""),
        footer = stringOr(d.footer, ""),
        bundle_url = Data.bundleUrl(d.bundleUrl),
        cooking = settings.cooking ~= false,
        text_size = ({ normal = 1, large = 1.15, huge = 1.3 })[settings.textSize] or 1,
        plain_font = settings.font == "plain",
        chapters = chapters,
        chapter_by_id = chapter_by_id,
        recipes = recipes,
        az = az,
        letters = letters,
        by_letter = by_letter,
        count = #az,
        latest = Data.decodeJSON(Data.readFile(dir .. "/latest.json")) or {},
    }
end

-- A picture from the bundle, or nil if it isn't there.
function Data.art(data, name)
    if not data or not name then return nil end
    local path = data.dir .. "/art/" .. name .. ".png"
    if isFile(path) then return path end
    return nil
end

-- "2026-11-17" -> "17 November 2026"
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December" }
function Data.longDate(ymd)
    local y, m, d = tostring(ymd or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return string.format("%d %s %s", tonumber(d), MONTHS[tonumber(m)] or "?", y)
end

return Data
