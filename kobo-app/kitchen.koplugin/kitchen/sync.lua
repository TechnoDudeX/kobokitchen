--[[
The kitchen recipe box: "Get new recipes" (OPTIONAL: Wi-Fi updates).

Only offered when the recipes name a website (book.json's bundleUrl, an https:// address of
your own: see the README). Without one, the kitchen never turns Wi-Fi on, and new recipes come
by cable (tools/kobo-install.mjs).

Turns on Wi-Fi, reads latest.json from the website (made by tools/kitchen-publish.mjs on the
computer), and when the recipes there differ from the ones on the Kobo and are newer:
  1. builds the new edition in kitchen/new/: files that didn't change are copied from the
     current edition, the rest are downloaded, and every file must have the size and SHA-256
     that latest.json lists;
  2. checks the new recipes can be read;
  3. swaps them in (kitchen/current -> old, new -> current, then old is removed; data.lua puts
     a swap that was cut off right on the next start).
Nothing on the Kobo changes unless all of that worked. Wi-Fi goes off again afterwards (if it
was off before), and the cook gets one plain sentence about what happened.

Newer: every latest.json says when it was built ("built", from the computer's clock, not the
Kobo's). Recipes put on by cable after the website was last updated are newer than the
website's, so a Wi-Fi update leaves them alone instead of going back to the website's older
ones. (tools/kitchen-publish.mjs --bump makes the website's the newest again.)

The website is only believed over HTTPS with its certificate checked: signed by an authority
on KOReader's own list (or the Let's Encrypt roots that come with this app), and made out to
the website's name. KOReader 2026.07 checks neither unless asked, and never the name, so both
are done here.
]]
local Data = require("kitchen/data")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local sha2 = require("ffi/sha2")

local Sync = {
    MAX_FILES = 200,
    MAX_BYTES = 8 * 1024 * 1024, -- the whole bundle is ~200 KB; anything near this is wrong
    WAIT = 75,                   -- seconds to wait for Wi-Fi once it has started connecting
    plugin_dir = nil,            -- set by main.lua: where isrg-roots.pem is
}

-- A date before this app was made means the Kobo's clock is wrong, and then no website's
-- certificate can be checked. (Only used to say so, when getting recipes fails.)
local MADE = os.time{ year = 2026, month = 11, day = 1, hour = 12 }

local function isFile(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- The certificate authorities to check the website against: KOReader's own list (in its
-- data/ folder, where KOReader runs), or else the Let's Encrypt roots that come with this app.
local function caFile()
    local koreader_list = (lfs.currentdir() or ".") .. "/data/ca-bundle.crt"
    if isFile(koreader_list) then return koreader_list end
    local ours = Sync.plugin_dir and (Sync.plugin_dir .. "/isrg-roots.pem")
    if isFile(ours) then return ours end
    return nil
end

-- Does a name in a certificate cover this host? ("*.example.com" covers one more label.)
local function nameCovers(name, host)
    if type(name) ~= "string" then return false end
    name, host = name:lower(), host:lower()
    if name == host then return true end
    local rest = name:match("^%*(%..+)$")
    if rest and #host > #rest and host:sub(-#rest) == rest then
        return not host:sub(1, #host - #rest):find(".", 1, true)
    end
    return false
end

-- Is this certificate made out to this host? Its alternative names, or else its common name.
local function certificateIsFor(cert, host)
    local names = {}
    local ok, ext = pcall(cert.extensions, cert)
    local alt = ok and type(ext) == "table" and ext["2.5.29.17"]
    if type(alt) == "table" and type(alt.dNSName) == "table" then
        for _, n in ipairs(alt.dNSName) do table.insert(names, n) end
    end
    if #names == 0 then
        local ok2, subject = pcall(cert.subject, cert)
        if ok2 and type(subject) == "table" then
            for _, e in ipairs(subject) do
                if type(e) == "table" and (e.oid == "2.5.4.3" or e.name == "commonName") then
                    table.insert(names, e.value)
                end
            end
        end
    end
    for _, n in ipairs(names) do
        if nameCovers(n, host) then return true end
    end
    return false
end

-- LuaSocket's way in for a connection of our own: LuaSec's HTTPS connection, checking the
-- certificate's chain (verify "peer"), and then, once it's open, the name in it.
local function checkedConnection(host, cafile)
    local https = require("ssl.https")
    local create = https.tcp({ verify = "peer", cafile = cafile })
    return function()
        local conn = create()
        local connect = conn.connect
        conn.connect = function(self, h, port)
            local ok, err = connect(self, h, port)
            if not ok then return ok, err end
            local cert = self.sock and self.sock.getpeercertificate and self.sock:getpeercertificate()
            if not (cert and certificateIsFor(cert, host)) then
                return nil, "the website's certificate isn't for " .. host
            end
            return ok
        end
        return conn
    end
end

-- One file from the website as a string, or nil and a reason.
function Sync.fetch(url)
    local host = url:match("^https://([^/:?#]+)")
    if not host then return nil, "not an https address: " .. url end
    local cafile = caFile()
    if not cafile then return nil, "there's no list of certificate authorities to check the website with" end
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local chunks = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code, _, status = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "GET",
            redirect = false, -- the website answers these addresses directly
            headers = { ["Accept-Encoding"] = "identity" },
            sink = socketutil.table_sink(chunks),
            create = checkedConnection(host, cafile),
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("kitchen: fetching", url, "failed:", code)
        return nil, tostring(code)
    end
    if code ~= 200 then
        logger.warn("kitchen: fetching", url, "gave", code, status)
        return nil, (type(code) == "number") and ("the website answered " .. code) or tostring(code)
    end
    return table.concat(chunks)
end

-- Writes a file and makes sure it is really on the Kobo's storage before going on: every step
-- (write, flush, sync to the card, close) has to say it worked.
local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(data)
    if ok then ok, werr = f:flush() end
    if ok then
        local called, synced, serr = pcall(ffiutil.fsyncOpenedFile, f)
        if not (called and synced) then
            ok, werr = nil, (called and serr) or synced or "it couldn't be saved"
        end
    end
    local closed, cerr = f:close()
    if not ok then return nil, werr end
    if not closed then return nil, cerr end
    return true
end

-- Is this file of an edition there, whole and as latest.json says?
local function intact(dir, f)
    local data = Data.readFile(dir .. "/" .. f.path)
    return data ~= nil and #data == f.bytes and sha2.sha256(data) == f.sha256
end

-- The files latest.json lists, checked: only recipes.json and art/<name>.png, each with a size
-- and a SHA-256, recipes.json among them.
local function checkedFiles(latest)
    if type(latest) ~= "table" or latest.format ~= Data.FORMAT or type(latest.files) ~= "table" then return nil end
    local files, total, seen, has_recipes = {}, 0, {}, false
    for _, f in ipairs(latest.files) do
        if type(f) ~= "table" or type(f.path) ~= "string" or type(f.bytes) ~= "number" or type(f.sha256) ~= "string" then return nil end
        local ok_path = f.path == "recipes.json" or f.path:match("^art/[%w%-_]+%.png$") ~= nil
        if not ok_path or seen[f.path] or not f.sha256:match("^%x+$") or #f.sha256 ~= 64
            or f.bytes < 0 or f.bytes ~= math.floor(f.bytes) then
            return nil
        end
        seen[f.path] = true
        if f.path == "recipes.json" then has_recipes = true end
        total = total + f.bytes
        table.insert(files, { path = f.path, bytes = f.bytes, sha256 = f.sha256:lower() })
    end
    if not has_recipes or #files > Sync.MAX_FILES or total > Sync.MAX_BYTES then return nil end
    return files
end

local function sameFiles(a, b)
    if not a or not b or #a ~= #b then return false end
    local index = {}
    for _, f in ipairs(b) do index[f.path] = f.sha256 end
    for _, f in ipairs(a) do
        if index[f.path] ~= f.sha256 then return false end
    end
    return true
end

-- When an edition was built, as latest.json says ("2026-11-18T14:03:12Z", always in UTC and
-- always this shape, so two can be compared as text), or nil if it doesn't say.
local function builtAt(latest)
    local s = type(latest) == "table" and latest.built
    if type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then return s end
    return nil
end

-- Was edition a built before edition b? Only when both say when they were built: an edition
-- that doesn't say is never held back.
local function builtBefore(a, b)
    local at, bt = builtAt(a), builtAt(b)
    return at ~= nil and bt ~= nil and at < bt
end

-- What changed between two loaded editions, by recipe name.
local function differences(old, new)
    local added, changed, gone = {}, {}, {}
    local function same(a, b)
        if a.title ~= b.title or a.aka ~= b.aka or a.gap ~= b.gap or #a.notes ~= #b.notes or #a.sections ~= #b.sections then return false end
        for i, n in ipairs(a.notes) do if b.notes[i] ~= n then return false end end
        for i, s in ipairs(a.sections) do
            local t = b.sections[i]
            if s.heading ~= t.heading or #s.ingredients ~= #t.ingredients or #s.steps ~= #t.steps then return false end
            for k, x in ipairs(s.ingredients) do
                if x.amount ~= t.ingredients[k].amount or x.text ~= t.ingredients[k].text then return false end
            end
            for k, x in ipairs(s.steps) do if t.steps[k] ~= x then return false end end
        end
        return true
    end
    for _, slug in ipairs(new.az) do
        local r = new.recipes[slug]
        local before = old and old.recipes[slug]
        if not before then table.insert(added, r.title)
        elseif not same(before, r) then table.insert(changed, r.title) end
    end
    if old then
        for _, slug in ipairs(old.az) do
            if not new.recipes[slug] then table.insert(gone, old.recipes[slug].title) end
        end
    end
    return added, changed, gone
end

-- Why the website couldn't be read, for the cook (and whoever looks after the Kobo).
local function unreachable(err)
    if os.time() < MADE then
        -- (after a flat battery the Kobo thinks it's 2012; joining Wi-Fi usually sets it right)
        return "the Kobo's date is wrong (it says " .. os.date("%d %B %Y") .. "), so it can't check the website yet. "
            .. "Joining Wi-Fi usually puts the date right: try again in a minute"
    end
    return "couldn't reach the website (" .. tostring(err) .. ")"
end

-- Does the whole update. Returns a result table, or nil and a reason for the cook.
function Sync.update(current_data)
    local base = current_data and current_data.bundle_url
    if not base then return nil, "there's no website set up to get new recipes from" end
    local text, err = Sync.fetch(base .. "latest.json?t=" .. os.time())
    if not text then return nil, unreachable(err) end
    local latest = Data.decodeJSON(text)
    local files = checkedFiles(latest)
    if not files then
        if latest and type(latest.format) == "number" and latest.format > Data.FORMAT then
            return nil, "the recipes on the website need a newer version of this app"
        end
        return nil, "the website's list of recipes doesn't look right"
    end
    local root, cur = Data.root(), Data.currentDir()
    local have_latest = Data.decodeJSON(Data.readFile(cur .. "/latest.json"))
    local have = checkedFiles(have_latest)
    local repairing = false
    if have and sameFiles(files, have) then
        -- The same edition: but is every file of it still whole on the Kobo? If not, the steps
        -- below put it right (downloading only what's damaged).
        local whole = true
        for _, f in ipairs(files) do
            if not intact(cur, f) then whole = false break end
        end
        if whole then return { changed = false, edition = latest.edition } end
        repairing = true
    elseif have and builtBefore(latest, have_latest) then
        -- Different recipes, but the Kobo's are newer: put on by cable after the website was
        -- last updated. Going back to the website's would undo them, so they stay.
        logger.info("kitchen: the website's recipes (built", builtAt(latest), ") are older than the Kobo's (built",
            builtAt(have_latest), "), so the Kobo keeps its own")
        return { changed = false, kept_newer = true, edition = have_latest.edition }
    end

    local new = root .. "/new"
    local downloaded = 0
    Data.removeTree(new)
    lfs.mkdir(root)
    lfs.mkdir(new)
    lfs.mkdir(new .. "/art")
    for _, f in ipairs(files) do
        local data = Data.readFile(cur .. "/" .. f.path)
        if not (data and #data == f.bytes and sha2.sha256(data) == f.sha256) then
            -- "?v=" makes sure no cache along the way hands back an older copy
            data, err = Sync.fetch(base .. f.path .. "?v=" .. f.sha256:sub(1, 16))
            downloaded = downloaded + 1
            if not data then
                Data.removeTree(new)
                return nil, "a file didn't download (" .. tostring(err) .. ")"
            end
            if #data ~= f.bytes or sha2.sha256(data) ~= f.sha256 then
                Data.removeTree(new)
                return nil, "a file came down damaged; the website may be halfway through an update, so try again in a few minutes"
            end
        end
        local ok, werr = writeFile(new .. "/" .. f.path, data)
        if not ok then
            Data.removeTree(new)
            return nil, "the Kobo couldn't save a file (" .. tostring(werr) .. ")"
        end
    end
    local ok, werr = writeFile(new .. "/latest.json", text)
    local new_data, why
    if ok then new_data, why = Data.load(new) else why = werr end
    if not new_data then
        Data.removeTree(new)
        return nil, "the new recipes couldn't be read (" .. tostring(why) .. ")"
    end

    -- the swap
    local old = root .. "/old"
    Data.removeTree(old)
    if lfs.attributes(cur, "mode") == "directory" then
        local moved, merr = os.rename(cur, old)
        if not moved then
            Data.removeTree(new)
            return nil, "the Kobo couldn't make room for the new recipes (" .. tostring(merr) .. ")"
        end
    end
    local swapped, serr = os.rename(new, cur)
    if not swapped then
        os.rename(old, cur)
        Data.removeTree(new)
        return nil, "the Kobo couldn't put the new recipes in place (" .. tostring(serr) .. ")"
    end
    pcall(ffiutil.fsyncDirectory, cur)
    pcall(Data.removeTree, old) -- (the new recipes are in; a leftover is tidied next start)
    local final = Data.load(cur)
    if not final then return nil, "the new recipes couldn't be read after all" end
    local added, changed, gone = differences(current_data, final)
    -- With no readable list on the Kobo and nothing downloaded, it was the list that was put right.
    return { changed = true, data = final, added = added, changed_titles = changed, gone = gone,
        edition = latest.edition, repaired = repairing or (have == nil and downloaded == 0) }
end

local function listOf(titles)
    if #titles <= 3 then return table.concat(titles, ", ") end
    return table.concat({ titles[1], titles[2], titles[3] }, ", ") .. string.format(" and %d more", #titles - 3)
end

-- One sentence (or two) for the cook.
function Sync.describe(result)
    local when = Data.longDate(result.edition)
    if result.kept_newer then
        return "You already have the newest recipes" .. (when and (" (" .. when .. ")") or "")
            .. ": the ones on the Kobo are newer than the website's."
    end
    if not result.changed then
        return "You already have the newest recipes" .. (when and (" (" .. when .. ").") or ".")
    end
    if result.repaired then
        return "A file of the recipes on the Kobo was damaged, and it's put right now. You have the newest recipes"
            .. (when and (" (" .. when .. ").") or ".")
    end
    local parts = {}
    if #result.added > 0 then
        table.insert(parts, string.format("%d new: %s.", #result.added, listOf(result.added)))
    end
    if #result.changed_titles > 0 then
        table.insert(parts, string.format("%d changed: %s.", #result.changed_titles, listOf(result.changed_titles)))
    end
    if #result.gone > 0 then
        table.insert(parts, string.format("%d taken out: %s.", #result.gone, listOf(result.gone)))
    end
    if #parts == 0 then table.insert(parts, "The pictures or words of the book changed.") end
    return "New recipes are in!\n\n" .. table.concat(parts, "\n")
end

--[[ The "Get new recipes" button: Wi-Fi on, update, Wi-Fi off, then tell the cook.

If the Kobo already has a connection, the update runs straight away (and if the website can't
be reached, the cook is told just that). Otherwise KOReader turns Wi-Fi on (blocking while it
joins the network) and calls back once it has an address; when joining fails it never calls
back (it shows its own short message and turns Wi-Fi off). So, after asking it:
  - while KOReader is still connecting (one of its own "pending" flags is up), check every
    second until it's done, and then either it called back already or there's no connection;
  - if Wi-Fi is off again straight away, that try failed: Kobos often miss the first one, so
    there's one more.
If the Kobo goes to sleep in the middle (KOReader turns Wi-Fi off then), it all stops quietly:
nothing runs or shows up behind the sleep screen, and the kitchen works again on waking. ]]
function Sync.getNewRecipes(screen, on_new)
    if screen.busy then return end
    -- No website set up: Wi-Fi stays off (the screens don't offer this then anyway).
    if not (screen.data and screen.data.bundle_url) then
        UIManager:show(InfoMessage:new{ text = "New recipes come by cable: there's no website set up to get them over Wi-Fi." })
        return
    end
    screen:setBusy(true)
    local was_on = NetworkMgr:isWifiOn()
    local finished, tries, waited = false, 0, 0
    local connecting -- KOReader's "Connecting to Wi-Fi…" message, while it may be up
    local poll, attempt
    -- What was on screen before: KOReader's own messages that come up during this (some, like
    -- "Error connecting to the network", stay until tapped) are closed when it ends.
    local before = {}
    for w in UIManager:topdown_widgets_iter() do before[w] = true end

    local function stop()
        finished = true
        screen.cancel_sync = nil
        UIManager:unschedule(poll)
        UIManager:unschedule(attempt)
        if connecting and UIManager:isWidgetShown(connecting) then UIManager:close(connecting) end
        connecting = nil
        local leftovers = {}
        for w in UIManager:topdown_widgets_iter() do
            if not before[w] and getmetatable(w) == InfoMessage then table.insert(leftovers, w) end
        end
        for _, w in ipairs(leftovers) do UIManager:close(w) end
    end
    local function finish(text)
        if finished then return end
        stop()
        screen:setBusy(false)
        if not was_on and NetworkMgr:isWifiOn() then
            local ok, err = pcall(NetworkMgr.disableWifi, NetworkMgr, nil, true)
            if not ok then logger.err("kitchen: couldn't turn Wi-Fi off:", err) end
        end
        -- Draw what changed first; then the message, which ignores taps made while the Kobo was
        -- busy (they would close it before it could be read, or press a button underneath).
        UIManager:forceRePaint()
        UIManager:show(InfoMessage:new{ text = text, flush_events_on_show = true })
    end
    local function couldnt(why)
        local dot = why:match("[%.%?!]$") and "" or "."
        finish("Couldn't get new recipes: " .. why .. dot .. "\n\nThe recipes on the Kobo are just as they were.")
    end
    -- Everything KOReader may call later runs guarded: a mistake becomes a message, never a crash.
    local function guarded(fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                logger.err("kitchen: Get new recipes failed:", err)
                if not finished then couldnt("something went wrong") end
            end
        end
    end
    local work = guarded(function()
        if finished then return end
        UIManager:unschedule(poll)
        connecting = nil -- KOReader closes its own message when it calls back
        local msg = InfoMessage:new{ text = "Getting new recipes…", dismissable = false }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, result, err = pcall(Sync.update, screen.data)
        UIManager:close(msg)
        if not ok then
            logger.err("kitchen: update failed:", result)
            return couldnt("something went wrong")
        end
        if not result then return couldnt(err) end
        local text = Sync.describe(result) -- (from what happened, before the screen changes)
        if result.changed then
            screen:setData(result.data)
            if on_new then pcall(on_new, result.data) end
        end
        finish(text)
    end)
    local function stillConnecting()
        return NetworkMgr.pending_connectivity_check or NetworkMgr.pending_connection
    end
    poll = guarded(function()
        if finished then return end
        waited = waited + 1
        if stillConnecting() and waited < Sync.WAIT then
            UIManager:scheduleIn(1, poll)
        elseif NetworkMgr:isConnected() then
            work()
        else
            couldnt("the Wi-Fi didn't connect")
        end
    end)
    attempt = guarded(function()
        if finished then return end
        tries = tries + 1
        if NetworkMgr:isConnected() then return work() end
        local shown = NetworkMgr:beforeWifiAction(work)
        if finished then return end
        if type(shown) == "table" then connecting = shown end
        if stillConnecting() then
            waited = 0
            UIManager:scheduleIn(1, poll)
        elseif NetworkMgr:isConnected() then
            work()
        elseif tries < 2 then
            UIManager:scheduleIn(3, attempt)
        else
            couldnt("the Wi-Fi didn't connect. Is the Kobo set up for this Wi-Fi?")
        end
    end)
    -- The Kobo is going to sleep (ui.lua's onSuspend): give up quietly. KOReader turns Wi-Fi off.
    screen.cancel_sync = function()
        if finished then return end
        stop()
        screen:setBusy(false)
    end
    attempt()
end

Sync._test = {
    checkedFiles = checkedFiles, sameFiles = sameFiles, differences = differences,
    nameCovers = nameCovers, certificateIsFor = certificateIsFor, builtBefore = builtBefore,
}

return Sync
