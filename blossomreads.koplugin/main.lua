--[[--
Blossom Reads ❀ Goodreads sync for KOReader, in Blossom's style.

Sync works like iCloud Sync: when Wi-Fi connects, on wake (if already online)
and when a book is closed, throttled and never two at once. It is quiet unless
something changed. Network work runs on the UI thread with short timeouts.
--]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Api = require("blossomreads_api")
local Engine = require("blossomreads_engine")
local Identify = require("blossomreads_identify")
local Login = require("blossomreads_login")
local Plan = require("blossomreads_plan")
local Store = require("blossomreads_store")

local SETTINGS_KEY = "blossomreads"
local DEFAULTS = {
    auto_on_wifi = true,
    auto_on_resume = true,
    auto_on_close = true,
    auto_link = true,
    complete_at_99 = false,
    share_goal = true,
    remember_password = true,
    sync_collections = true,
}
local LINK_PER_RUN = 8
local RETRY_UNMATCHED = 7 * 24 * 3600
local AUTO_THROTTLE = 5 * 60

-- Shared by the file-manager and reader instances of the plugin.
local running, last_auto, told_signin = false, 0, false

local BlossomReads = WidgetContainer:extend{
    name = "blossomreads",
    is_doc_only = false,
}

function BlossomReads._resetForTests()
    running, last_auto, told_signin = false, 0, false
end

function BlossomReads:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function BlossomReads:onDispatcherRegisterActions()
    Dispatcher:registerAction("blossomreads_sync", {
        category = "none", event = "BlossomReadsSync", title = _("Blossom Reads: sync now"), general = true,
    })
    Dispatcher:registerAction("blossomreads_open", {
        category = "none", event = "BlossomReadsOpen", title = _("Blossom Reads: open"), general = true,
    })
    Dispatcher:registerAction("blossomreads_book", {
        category = "none", event = "BlossomReadsBook", title = _("Blossom Reads: this book"), reader = true,
    })
end

--------------------------------------------------------------------------------
-- Settings (one table in G_reader_settings, as in iCloud Sync)
--------------------------------------------------------------------------------

function BlossomReads:getSetting(key)
    local t = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    if t[key] == nil then return DEFAULTS[key] end
    return t[key]
end

function BlossomReads:setSetting(key, value)
    local t = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    t[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, t)
    G_reader_settings:flush()
end

--------------------------------------------------------------------------------
-- Blossom link
--------------------------------------------------------------------------------

function BlossomReads:blossomInstalled()
    if self._blossom == nil then
        local dir = (self.path or ".") .. "/../blossom.koplugin"
        self._blossom = lfs.attributes(dir, "mode") == "directory"
    end
    return self._blossom
end

function BlossomReads.blossomGoal()
    local b = G_reader_settings:readSetting("blossom")
    return b and b.yearly_goal
end

function BlossomReads.setBlossomGoal(n)
    local b = G_reader_settings:readSetting("blossom") or {}
    b.yearly_goal = n
    G_reader_settings:saveSetting("blossom", b)
    G_reader_settings:flush()
end

-- Books Blossom counted as finished this year (only while Blossom is loaded).
function BlossomReads:blossomCount()
    local blossom = self.ui and self.ui.blossom
    if not (blossom and blossom.loadYear) then return nil end
    local ok, year = pcall(blossom.loadYear, blossom, tonumber(os.date("%Y")))
    return ok and type(year) == "table" and year.finished or nil
end

function BlossomReads:goalLinked()
    return self:getSetting("share_goal") and self:blossomInstalled()
end

--------------------------------------------------------------------------------
-- Books and progress
--------------------------------------------------------------------------------

function BlossomReads:currentFile()
    local doc = self.ui and self.ui.document
    return doc and doc.file
end

local function wholePercent(f)
    f = tonumber(f)
    if not f then return nil end
    return math.max(0, math.min(100, math.floor(f * 100)))
end

-- Live values of the open book (its .sdr may be older).
function BlossomReads:liveProgress()
    local ui = self.ui
    if not (ui and ui.document) then return nil end
    local mod = ui.paging or ui.rolling
    local ok, f = pcall(function() return mod and mod:getLastPercent() end)
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    return { pct = wholePercent(ok and f), status = type(summary) == "table" and summary.status or nil }
end

local function savedProgress(file)
    local DocSettings = require("docsettings")
    if not DocSettings:hasSidecarFile(file) then return nil end
    local ds = DocSettings:open(file)
    local summary = ds:readSetting("summary")
    return { pct = wholePercent(ds:readSetting("percent_finished")), status = type(summary) == "table" and summary.status or nil }
end

local function sidecarTime(file)
    local path = require("docsettings"):findSidecarFile(file)
    return path and lfs.attributes(path, "modification") or 0
end

--------------------------------------------------------------------------------
-- Collections and linking
--------------------------------------------------------------------------------

-- { [file] = { "To Be Read", "favorites" } } from KOReader's collections.
function BlossomReads.collectionsOf()
    local out = {}
    local ok, ReadCollection = pcall(require, "readcollection")
    if not (ok and ReadCollection) then return out end
    pcall(ReadCollection._read, ReadCollection)
    for name, items in pairs(ReadCollection.coll or {}) do
        for file in pairs(items) do
            out[file] = out[file] or {}
            table.insert(out[file], name)
        end
    end
    for _i, names in pairs(out) do table.sort(names) end
    return out
end

-- The Goodreads shelves for a book's collections (per the Collections → shelves settings).
function BlossomReads:shelvesFor(names)
    if not (names and self:getSetting("sync_collections")) then return nil end
    local map, out, seen = self:getSetting("collection_map") or {}, {}, {}
    for _i, name in ipairs(names) do
        local slug = Plan.collectionShelf(name, map[name])
        if slug and not seen[slug] then
            seen[slug] = true
            out[#out + 1] = slug
        end
    end
    return out
end

-- What KOReader knows about a book without opening it: its .sdr, then Cover Browser's cache
-- (nil means the file name is used).
local function metadataFor(file)
    local DocSettings = require("docsettings")
    if DocSettings:hasSidecarFile(file) then
        local props = DocSettings:open(file):readSetting("doc_props")
        if type(props) == "table" and (props.title or "") ~= "" then return props end
    end
    local bim = package.loaded["bookinfomanager"]
    if bim and bim.getBookInfo then
        local ok, info = pcall(bim.getBookInfo, bim, file)
        if ok and type(info) == "table" and (info.title or "") ~= "" then return info end
    end
end

-- Link books from collections and reading history that aren't linked yet (a few per sync).
-- Returns how many were linked, and a stop error if Goodreads can't be reached.
function BlossomReads:linkPending(api, books, collections, now)
    local files, seen = {}, {}
    local function add(file)
        if file and not seen[file] then
            seen[file] = true
            files[#files + 1] = file
        end
    end
    local in_coll = {}
    for file in pairs(collections or {}) do in_coll[#in_coll + 1] = file end
    table.sort(in_coll)
    for _i, file in ipairs(in_coll) do add(file) end
    local ok, ReadHistory = pcall(require, "readhistory")
    for _i, item in ipairs(ok and ReadHistory and ReadHistory.hist or {}) do add(item.file) end

    local linked, tried = 0, 0
    for _i, file in ipairs(files) do
        if tried >= LINK_PER_RUN then break end
        local entry = books[file] or {}
        local recent_miss = entry.unmatched_at and now - entry.unmatched_at < RETRY_UNMATCHED
        if not entry.gid and not recent_miss and lfs.attributes(file, "mode") == "file" then
            tried = tried + 1
            local want = Identify.fromProps(metadataFor(file), file)
            local match, how, _ranked, err = Identify.match(function(q) return api:search(q) end, want)
            if err == "signin" or err == "network" or err == "blocked" then return linked, err end
            if match then
                books[file] = { gid = match.gid, title = match.title, author = match.author, cover = match.cover, linked = how }
                linked = linked + 1
            elseif not err then
                entry.unmatched_at = now
                books[file] = entry
            end
        end
    end
    return linked
end

-- opts.only: one file; opts.since: skip books whose .sdr hasn't changed; opts.live: { [file] = progress }
-- Books in a collection (or that were) are always planned: their shelves may have changed.
function BlossomReads:collect(books, opts, collections)
    collections = collections or {}
    local items, open = {}, self:currentFile()
    for file, entry in pairs(books) do
        if entry.gid and (not opts.only or opts.only == file) then
            local names = collections[file]
            local tracked = (names and self:getSetting("sync_collections")) or entry.collections_sent
            local now = opts.live and opts.live[file]
            if not now and file == open then now = self:liveProgress() end
            if not now and (tracked or not opts.since or sidecarTime(file) > opts.since) then now = savedProgress(file) end
            if not now and tracked then now = {} end
            if now then items[#items + 1] = { file = file, now = now, shelves = self:shelvesFor(names) or {} } end
        end
    end
    table.sort(items, function(a, b) return a.file < b.file end)
    return items
end

function BlossomReads:api()
    local s = Login.session()
    return Api.new{ cookies = s.cookies, user_id = s.user_id, transport = self.transport }
end

-- Keep rotated cookies, without rewriting the file when nothing changed.
function BlossomReads:keepSession(api)
    local s = Login.session()
    if api:cookies() ~= s.cookies or (api.user_id and api.user_id ~= s.user_id) then
        Login.saveSession(api:cookies(), api.user_id or s.user_id, "valid")
    end
end

--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

local function isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr and NetworkMgr:isConnected() and true or false
end

-- A soft Blossom note: script font, no "i" icon (a ♡ in the text says enough).
function BlossomReads.note(text, timeout)
    local Theme = require("blossomreads_theme")
    return InfoMessage:new{ text = text, timeout = timeout, show_icon = false, face = Theme.face("script", 19) }
end

function BlossomReads:card(text, timeout)
    UIManager:show(self.note(text, timeout or 3))
end

function BlossomReads:autoSync()
    if running or not Login.signedIn() then return end
    if os.time() - last_auto < AUTO_THROTTLE then return end
    last_auto = os.time()
    local since = (self:getSetting("last_sync") or {}).time
    UIManager:scheduleIn(2, function() self:runSync{ auto = true, since = since } end)
end

function BlossomReads:onNetworkConnected()
    if self:getSetting("auto_on_wifi") then self:autoSync() end
end

function BlossomReads:onResume()
    if self:getSetting("auto_on_resume") and isOnline() then self:autoSync() end
end

function BlossomReads:onCloseDocument()
    local file = self:currentFile()
    if not (file and self:getSetting("auto_on_close") and Login.signedIn() and isOnline()) then return end
    local books = Store.open("books").data
    if not (books[file] and books[file].gid) then return end
    local live = { [file] = self:liveProgress() }
    UIManager:scheduleIn(2, function() self:runSync{ auto = true, only = file, live = live } end)
end

function BlossomReads:onReaderReady()
    local file = self:currentFile()
    if not (file and self:getSetting("auto_link") and Login.signedIn()) then return end
    local entry = Store.open("books"):get(file)
    if entry and entry.gid then return end
    if not isOnline() then return end
    UIManager:scheduleIn(2, function() self:autoLink(file) end)
end

function BlossomReads:onBlossomReadsSync()
    self:syncNow()
end

function BlossomReads:syncNow()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function() self:runSync{} end)
    else
        self:runSync{}
    end
end

function BlossomReads:runSync(o)
    o = o or {}
    if running then return end
    if not Login.signedIn() then
        if not o.auto then self:card(_("Please sign in to Goodreads first ♡\nTools → Blossom Reads."), 4) end
        return
    end
    running = true
    local msg
    if not o.auto then
        msg = self.note(_("Syncing petals…"))
        UIManager:show(msg)
        UIManager:forceRePaint()
    end
    local ok, s = pcall(self._sync, self, o)
    if msg then UIManager:close(msg) end
    running = false
    if not ok then
        logger.warn("BlossomReads: sync crashed:", s)
        s = { error = "crash", time = os.time() }
    end
    self:report(s, o.auto)
    return s
end

function BlossomReads:_sync(o)
    local api = self:api()
    local store = Store.open("books")
    local goal
    if self:goalLinked() then
        goal = { get = self.blossomGoal, set = self.setBlossomGoal, synced = self:getSetting("goal_synced") }
    end
    local collections = self.collectionsOf()
    local linked, link_err = 0, nil
    if not o.only then
        local before = Store.serialize(store.data)
        linked, link_err = self:linkPending(api, store.data, self:getSetting("sync_collections") and collections or {}, os.time())
        if Store.serialize(store.data) ~= before then store.dirty = true end
    end
    local s
    if link_err then
        s = { time = os.time(), books = 0, pushed = 0, shelved = 0, failed = 0, error = link_err }
    else
        s = Engine.run{
            api = api,
            books = store.data,
            items = self:collect(store.data, o, collections),
            opts = { complete_at_99 = self:getSetting("complete_at_99") },
            goal = goal,
        }
    end
    s.linked = linked
    if linked > 0 then s.changed = true end
    if s.changed or store.dirty then
        store.dirty = true
        store:flush()
    end
    if s.synced then self:setSetting("goal_synced", s.synced) end
    if s.challenge then
        self:setSetting("challenge", { goal = s.challenge.goal, read = s.challenge.read, at = s.time })
    end
    if s.error == "signin" then
        Login.markExpired()
    else
        self:keepSession(api)
    end
    self:setSetting("last_sync", {
        time = s.time, books = s.books, linked = s.linked, failed = s.failed, error = s.error,
        goal = s.goal and { value = s.goal.value } or nil,
    })
    return s
end

local ERRORS = {
    signin = _("Goodreads asked you to sign in again ♡"),
    network = _("Couldn't sync — no Wi-Fi ☆"),
    blocked = _("Goodreads is busy right now, please try again later ☆"),
    crash = _("Something went wrong ☆"),
}

function BlossomReads.summaryText(s)
    if s.error and ERRORS[s.error] then return ERRORS[s.error] end
    local parts = {}
    if (s.books or 0) == 1 then
        parts[#parts + 1] = _("1 book updated")
    elseif (s.books or 0) > 1 then
        parts[#parts + 1] = T(_("%1 books updated"), s.books)
    end
    if (s.linked or 0) == 1 then
        parts[#parts + 1] = _("1 book linked")
    elseif (s.linked or 0) > 1 then
        parts[#parts + 1] = T(_("%1 books linked"), s.linked)
    end
    if s.goal and s.goal.value then parts[#parts + 1] = T(_("goal set to %1 ♥"), s.goal.value) end
    if (s.failed or 0) > 0 then parts[#parts + 1] = T(_("%1 couldn't sync"), s.failed) end
    if #parts == 0 then return _("Up to date ♡") end
    return _("Goodreads ♡ ") .. table.concat(parts, " · ")
end

function BlossomReads:report(s, auto)
    if not auto then
        self:card(self.summaryText(s), 4)
    elseif s.error == "signin" then
        if not told_signin then
            told_signin = true
            self:card(ERRORS.signin, 4)
        end
    elseif s.error then
        logger.info("BlossomReads: auto sync failed:", s.error)
    elseif s.changed then
        self:card(self.summaryText(s), 3)
    end
end

function BlossomReads:statusText()
    local last = self:getSetting("last_sync")
    if not (last and last.time) then return _("Last sync: never") end
    local when = os.date(os.date("%Y%m%d", last.time) == os.date("%Y%m%d") and "%H:%M" or "%b %d, %H:%M", last.time)
    if last.error then return T(_("Last sync: %1 — failed"), when) end
    local summary = self.summaryText(last):gsub("^" .. _("Goodreads ♡ "), "")
    return T(_("Last sync: %1 — %2"), when, summary)
end

-- Network work started from a screen: a "gathering petals" card while it runs,
-- the session kept up to date, and a friendly card on failure.
-- fn(api) -> value, err. Returns value, err.
function BlossomReads:busy(fn, text)
    if not Login.signedIn() then
        self:card(_("Please sign in to Goodreads first ♡\nTools → Blossom Reads."), 4)
        return nil, "signin"
    end
    local msg = self.note(text or _("Gathering petals…"))
    UIManager:show(msg)
    UIManager:forceRePaint()
    local api = self:api()
    local ok, value, err = pcall(fn, api)
    UIManager:close(msg)
    if not ok then
        logger.warn("BlossomReads: request crashed:", value)
        value, err = nil, "crash"
    end
    if err == "signin" then
        Login.markExpired()
    elseif err ~= "network" then
        self:keepSession(api)
    end
    if err then self:card(ERRORS[err] or _("Goodreads didn't answer properly ☆"), 4) end
    return value, err
end

--------------------------------------------------------------------------------
-- Linking books
--------------------------------------------------------------------------------

function BlossomReads:linkBook(file, book, how)
    local store = Store.open("books")
    local old = store:get(file) or {}
    store:set(file, {
        gid = book.gid, title = book.title, author = book.author, cover = book.cover,
        linked = how or "manual", rating = old.gid == book.gid and old.rating or nil,
    })
    store:flush()
end

function BlossomReads:unlinkBook(file)
    local store = Store.open("books")
    store:delete(file)
    store:flush()
end

-- Returns match, ranked candidates, err.
function BlossomReads:findMatches(file, props)
    local want = Identify.fromProps(props or (self.ui and self.ui.doc_props), file)
    local api = self:api()
    local match, how, ranked, err = Identify.match(function(q) return api:search(q) end, want)
    return match, how, ranked, err
end

function BlossomReads:autoLink(file)
    if running then return end
    local ok, match, how, ranked = pcall(self.findMatches, self, file)
    if not ok then
        logger.warn("BlossomReads: link failed:", match)
        return
    end
    self._candidates = { file = file, list = ranked }
    if match then
        self:linkBook(file, match, how)
        self:card(T(_("Found on Goodreads ♡\n%1"), match.title or ""), 3)
    end
end

--------------------------------------------------------------------------------
-- Sign in
--------------------------------------------------------------------------------

function BlossomReads:signIn(touchmenu)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local saved = Login.credentials()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Sign in to Goodreads ♡"),
        fields = {
            { text = saved and saved.email or "", hint = _("Email") },
            { text = saved and saved.password or "", hint = _("Password"), text_type = "password" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Sign in"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:runWhenOnline(function()
                        self:loginStep(function() return Login.start(fields[1], fields[2], { transport = self.transport }) end,
                            fields[1], fields[2], touchmenu)
                    end)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BlossomReads:runWhenOnline(fn)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(fn)
    else
        fn()
    end
end

local LOGIN_ERRORS = {
    credentials = _("That email or password didn't work ☆"),
    blocked = _("Goodreads asked for a check that can't be done here. Please try again later ☆"),
    network = _("Couldn't reach Goodreads — check Wi-Fi ☆"),
    server = _("Goodreads didn't answer properly. Please try again in a little while ☆"),
    unexpected = _("Goodreads showed a page Blossom Reads doesn't know yet ☆"),
}

-- Run one sign-in step and follow up (code / puzzle / done).
function BlossomReads:loginStep(step, email, password, touchmenu)
    local msg = self.note(_("Signing in…"))
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, res = pcall(step)
    UIManager:close(msg)
    if not ok then
        logger.warn("BlossomReads: sign-in crashed:", res)
        res = { err = "unexpected" }
    end
    if res.ok then
        told_signin = false
        if self:getSetting("remember_password") and email then
            Login.saveCredentials(email, password)
        end
        self:card(_("Signed in to Goodreads ♡"), 3)
        if touchmenu then touchmenu:updateItems() end
    elseif res.need == "otp" then
        self:askText(_("Enter the code Amazon sent you"), function(code)
            self:loginStep(function() return Login.submitOtp(code) end, email, password, touchmenu)
        end)
    elseif res.need == "captcha" then
        self:showCaptcha(res.image_url, function(answer)
            self:loginStep(function() return Login.submitCaptcha(answer) end, email, password, touchmenu)
        end)
    else
        Login.cancel()
        self:card(LOGIN_ERRORS[res.err] or LOGIN_ERRORS.unexpected, 6)
    end
end

function BlossomReads:askText(title, on_done, not_login)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                if not not_login then Login.cancel() end
            end },
            {
                text = _("Continue"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    on_done(text)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BlossomReads:showCaptcha(url, on_done)
    local bytes = Login.captchaImage(url)
    if not bytes then
        Login.cancel()
        self:card(LOGIN_ERRORS.blocked, 6)
        return
    end
    local path = Store.dir() .. "/puzzle" .. (url:lower():find("%.png") and ".png" or ".jpg")
    Store.ensureDir()
    local f = io.open(path, "wb")
    if f then f:write(bytes); f:close() end
    local ImageViewer = require("ui/widget/imageviewer")
    -- However the picture is closed, ask for its characters next.
    local Puzzle = ImageViewer:extend{}
    function Puzzle:onCloseWidget()
        if ImageViewer.onCloseWidget then ImageViewer.onCloseWidget(self) end
        UIManager:nextTick(function() self.owner:askText(_("Characters in the picture"), on_done) end)
    end
    UIManager:show(Puzzle:new{ owner = self, file = path, with_title_bar = false,
        caption = _("Type these characters, then close ♡") })
end

function BlossomReads:signOut(touchmenu)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Sign out of Goodreads?"),
        ok_text = _("Sign out"),
        ok_callback = function()
            Login.signOut()
            if not self:getSetting("remember_password") then Login.forgetCredentials() end
            if touchmenu then touchmenu:updateItems() end
        end,
    })
end

--------------------------------------------------------------------------------
-- Screens (built in blossomreads_view / _book)
--------------------------------------------------------------------------------

function BlossomReads:onBlossomReadsOpen()
    self:showHome()
end

function BlossomReads:onBlossomReadsBook()
    self:showBook()
end

function BlossomReads:showHome()
    require("blossomreads_view").show(self)
end

function BlossomReads:showBook()
    local file = self:currentFile()
    if not file then return end
    require("blossomreads_book").show(self, file)
end

--------------------------------------------------------------------------------
-- Menu (Tools → ❀ Blossom Reads), laid out like iCloud Sync's
--------------------------------------------------------------------------------

-- Collections → shelves: one line per KOReader collection, each with its own choices.
local CHOICES = {
    { "auto", _("Automatic (by name)") },
    { "to-read", _("Want to Read") },
    { "currently-reading", _("Currently Reading") },
    { "read", _("Read") },
    { "did-not-finish", _("Did Not Finish") },
    { "off", _("Don't sync") },
}

function BlossomReads:setCollectionMap(name, value)
    local map = self:getSetting("collection_map") or {}
    map[name] = value ~= "auto" and value or nil
    self:setSetting("collection_map", map)
end

function BlossomReads:collectionChoices(name)
    local items = {}
    local function current()
        return (self:getSetting("collection_map") or {})[name] or "auto"
    end
    for _i, c in ipairs(CHOICES) do
        items[#items + 1] = {
            text = c[2],
            radio = true,
            checked_func = function() return current() == c[1] end,
            callback = function() self:setCollectionMap(name, c[1]) end,
        }
    end
    items[#items + 1] = {
        text_func = function()
            local v = current()
            local custom = v ~= "auto" and v ~= "off" and not Plan.isStatus(v)
            return custom and T(_("Another shelf: %1"), v) or _("Another shelf…")
        end,
        checked_func = function()
            local v = current()
            return v ~= "auto" and v ~= "off" and not Plan.isStatus(v)
        end,
        callback = function(touchmenu)
            self:askText(_("Goodreads shelf name"), function(text)
                local slug = Plan.slug(text)
                if slug ~= "" then self:setCollectionMap(name, slug) end
                if touchmenu then touchmenu:updateItems() end
            end, true)
        end,
    }
    return items
end

function BlossomReads:collectionMenu()
    local names = {}
    for name in pairs(self.collectionNames()) do names[#names + 1] = name end
    table.sort(names)
    local items = {}
    for _i, name in ipairs(names) do
        items[#items + 1] = {
            text_func = function()
                local slug = Plan.collectionShelf(name, (self:getSetting("collection_map") or {})[name])
                local shelf = slug and require("blossomreads_view").shelfName(slug) or _("not synced")
                return T("%1 → %2", name, shelf)
            end,
            sub_item_table_func = function() return self:collectionChoices(name) end,
        }
    end
    if #items == 0 then items[1] = { text = _("No collections yet ♡"), enabled = false } end
    return items
end

-- Every collection's name, including empty ones.
function BlossomReads.collectionNames()
    local out = {}
    local ok, ReadCollection = pcall(require, "readcollection")
    if ok and ReadCollection then
        pcall(ReadCollection._read, ReadCollection)
        for name in pairs(ReadCollection.coll or {}) do out[name] = true end
    end
    return out
end

local function toggle(self, key, text)
    return {
        text = text,
        checked_func = function() return self:getSetting(key) end,
        callback = function() self:setSetting(key, not self:getSetting(key)) end,
    }
end

function BlossomReads:addToMainMenu(menu_items)
    local items = {
        { text = _("Sync now"), callback = function() self:syncNow() end },
        {
            text_func = function() return self:statusText() end,
            keep_menu_open = true,
            separator = true,
            callback = function()
                local last = self:getSetting("last_sync")
                if last and last.error then self:card(self.summaryText(last), 5) end
            end,
        },
        { text = _("Open Blossom Reads"), callback = function() self:showHome() end },
        {
            text = _("This book"),
            enabled_func = function() return self:currentFile() ~= nil end,
            callback = function() self:showBook() end,
            separator = true,
        },
        toggle(self, "auto_on_wifi", _("Sync when Wi-Fi connects")),
        toggle(self, "auto_on_resume", _("Sync on wake")),
        toggle(self, "auto_on_close", _("Sync when closing a book")),
        toggle(self, "auto_link", _("Link books automatically")),
        toggle(self, "sync_collections", _("Sync collections to shelves")),
        {
            text = _("Collections → shelves"),
            enabled_func = function() return self:getSetting("sync_collections") end,
            sub_item_table_func = function() return self:collectionMenu() end,
        },
        toggle(self, "complete_at_99", _("Mark Read at 99%")),
    }
    items[#items].separator = not self:blossomInstalled()
    if self:blossomInstalled() then
        local share = toggle(self, "share_goal", _("Share my yearly goal with Blossom"))
        share.separator = true
        items[#items + 1] = share
    end
    items[#items + 1] = {
        text_func = function()
            local s = Login.session()
            if Login.signedIn() then return T(_("Signed in as %1"), s.user_id) end
            if s.state == "expired" then return _("Sign in again to Goodreads") end
            return _("Sign in to Goodreads")
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            if Login.signedIn() then self:signOut(touchmenu) else self:signIn(touchmenu) end
        end,
    }
    items[#items + 1] = {
        text = _("Remember password"),
        checked_func = function() return self:getSetting("remember_password") end,
        callback = function()
            local on = not self:getSetting("remember_password")
            self:setSetting("remember_password", on)
            if not on then Login.forgetCredentials() end
        end,
    }
    menu_items.blossomreads = {
        text = _("❀ Blossom Reads"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

return BlossomReads
