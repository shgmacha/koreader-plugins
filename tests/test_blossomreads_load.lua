-- Blossom Reads: loads the plugin against stubbed KOReader modules and drives
-- its events, menu, sign-in and screens with a fake Goodreads.
local H = require("tests.harness")
local test, eq = H.test, H.eq

-- A fresh, unique settings folder every run (math.random is unseeded, so it can repeat).
local SETTINGS = os.tmpname()
os.remove(SETTINGS)
os.execute('rm -rf "' .. SETTINGS .. '" && mkdir -p "' .. SETTINGS .. '"')

-- Widget stubs ---------------------------------------------------------------
local function class(kind)
    local C = { kind = kind }
    C.__index = C
    function C:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, self)
    end
    function C:new(o)
        o = setmetatable(o or {}, self)
        if o.init then o:init() end
        return o
    end
    function C:getSize()
        if self.kind == "FrameContainer" then
            local c = self[1] and self[1]:getSize() or { w = 0, h = 0 }
            local extra = 2 * ((self.padding or 5) + (self.bordersize or 0) + (self.margin or 0))
            return { w = (self.width or c.w + extra), h = (self.height or c.h + extra) }
        end
        if self.dimen and self.dimen.w then return { w = self.dimen.w, h = self.dimen.h or 0 } end
        if self.width and self.height then return { w = self.width, h = self.height } end
        if self.text then return { w = math.min(#self.text * 8, self.width or 1e9), h = 20 } end
        local w, h = 0, 0
        for _, c in ipairs(self) do
            local s = (type(c) == "table" and c.getSize) and c:getSize() or { w = 0, h = 0 }
            if self.kind == "VerticalGroup" or self.kind == "OverlapGroup" then
                w, h = math.max(w, s.w), (self.kind == "OverlapGroup" and math.max(h, s.h) or h + s.h)
            else
                w, h = w + s.w, math.max(h, s.h)
            end
        end
        return { w = self.width or w, h = self.height or h }
    end
    function C:free() self.freed = true end
    function C:paintTo() end
    function C:onShowKeyboard() end
    function C:getFields() return self.answer or {} end
    function C:getInputText() return self.answer or "" end
    return C
end

local shown, closed, scheduled = {}, {}, {}
local dispatched = {}
local online = true
local sidecars = {} -- file -> { percent_finished, summary, mtime, doc_props }
local on_disk = {}   -- files that exist
local collections = { coll = {} } -- stands in for KOReader's ReadCollection
function collections:_read() end
local history = { hist = {} }

local stubs = {
    ["ffi/blitbuffer"] = { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, Color8 = function(v) return v end },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["ui/size"] = {
        padding = { default = 5, small = 2, large = 10 }, margin = { default = 5 },
        border = { thin = 1, thick = 2, window = 1 }, radius = { window = 8 }, line = { thin = 1, medium = 1, thick = 2 },
    },
    ["ui/geometry"] = { new = function(_, o) return o end },
    ["ui/gesturerange"] = { new = function(_, o) return o end },
    ["device"] = {
        screen = {
            w = 600, h = 800,
            getWidth = function(self) return self.w end,
            getHeight = function(self) return self.h end,
            scaleBySize = function(_, n) return n end,
        },
        isTouchDevice = function() return true end,
        hasKeys = function() return true end,
        input = { group = { Back = { "Back" }, PgFwd = { "RPgFwd" }, PgBack = { "RPgBack" } } },
    },
    ["ui/uimanager"] = {
        show = function(_, w) table.insert(shown, w) end,
        restartKOReader = function() _G.RESTARTED = true end,
        close = function(_, w) table.insert(closed, w) end,
        setDirty = function() end,
        forceRePaint = function() end,
        scheduleIn = function(_, s, fn) table.insert(scheduled, { s = s, fn = fn }) end,
        nextTick = function(_, fn) table.insert(scheduled, { s = 0, fn = fn }) end,
    },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
    ["logger"] = { warn = function() end, info = function() end, dbg = function() end },
    ["datastorage"] = { getSettingsDir = function() return SETTINGS end },
    ["dispatcher"] = { registerAction = function(_, id, def) dispatched[id] = def end },
    ["ffi/util"] = { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end },
    ["readcollection"] = collections,
    ["util"] = { partialMD5 = function(file) return "abc123" end },
    ["lua-ljsqlite3/init"] = { open = function()
        return { rowexec = function(_, sql) _G.LAST_SQL = sql; return _G.STATS_FIRST end, close = function() end }
    end },
    ["readhistory"] = history,
    ["libs/libkoreader-lfs"] = { dir = function(p)
        local names, f = {}, io.popen('ls -a "' .. p .. '" 2>/dev/null')
        for line in f:lines() do names[#names + 1] = line end
        f:close()
        local i = 0
        return function() i = i + 1; return names[i] end
    end, attributes = function(p, what)
        if p:find("blossom%.koplugin$") then return _G.BLOSSOM_INSTALLED and "directory" or nil end
        if what == "mode" and on_disk[p] then return "file" end
        if _G.REAL_ROOT and p:sub(1, #_G.REAL_ROOT) == _G.REAL_ROOT and what == "mode" then
            if os.execute('test -d "' .. p .. '"') == 0 then return "directory" end
            if os.execute('test -f "' .. p .. '"') == 0 then return "file" end
            return nil
        end
        local sc = sidecars[p:match("^(.-)%.sdr$") or ""]
        if sc and what == "modification" then return sc.mtime or 0 end
        return nil
    end },
    ["docsettings"] = {
        hasSidecarFile = function(_, file) return sidecars[file] ~= nil end,
        findSidecarFile = function(_, file) return sidecars[file] and (file .. ".sdr") or nil end,
        open = function(_, file)
            return { readSetting = function(_, key) return sidecars[file] and sidecars[file][key] end }
        end,
    },
    ["ui/network/manager"] = {
        isConnected = function() return online end,
        runWhenOnline = function(_, fn) fn() end,
    },
}
for _, name in ipairs({
    "ui/widget/container/bottomcontainer", "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
    "ui/widget/imagewidget", "ui/widget/infomessage", "ui/widget/container/inputcontainer",
    "ui/widget/overlapgroup", "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/verticalgroup",
    "ui/widget/verticalspan", "ui/widget/widget", "ui/widget/container/widgetcontainer",
    "ui/widget/container/leftcontainer", "ui/widget/linewidget", "ui/widget/container/scrollablecontainer",
    "ui/widget/spinwidget", "ui/widget/multiinputdialog", "ui/widget/inputdialog", "ui/widget/confirmbox",
    "ui/widget/imageviewer", "ui/widget/container/movablecontainer", "ui/widget/buttondialog",
}) do
    local base = name:match("([^/]+)$")
    local kind = ({
        framecontainer = "FrameContainer", verticalgroup = "VerticalGroup", horizontalgroup = "HorizontalGroup",
        overlapgroup = "OverlapGroup", infomessage = "InfoMessage", multiinputdialog = "MultiInputDialog",
        inputdialog = "InputDialog", confirmbox = "ConfirmBox", imageviewer = "ImageViewer",
        textwidget = "TextWidget", textboxwidget = "TextBoxWidget", spinwidget = "SpinWidget",
        centercontainer = "CenterContainer", inputcontainer = "InputContainer", button = "Button",
        buttondialog = "ButtonDialog",
    })[base] or base
    stubs[name] = class(kind)
end

_G.G_reader_settings = {
    data = {},
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    flush = function(self) self.flushed = true end,
}
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end

-- Fake Goodreads -------------------------------------------------------------
local GR = "https://www.goodreads.com"
local REVIEW_LIST = [[<meta name="csrf-token" content="TOK" /><a href="/user/show/42-me">me</a>]]
local net = { log = {}, routes = {} }
local function resetNet()
    net.log = {}
    net.handler = nil
    net.routes = {
        [GR .. "/review/list"] = { 200, {}, REVIEW_LIST },
        [GR .. "/shelf/add_to_shelf"] = { 200, {}, "{}" },
        [GR .. "/user_status.json"] = { 200, {}, "{}" },
        [GR .. "/readingchallenges/goals/data"] = { 200, {}, [[{"readingGoal":24,"readingProgress":9,"daysRemaining":90}]] },
    }
end
resetNet()
local function transport(req)
    net.log[#net.log + 1] = req.method .. " " .. req.url:gsub("^" .. GR, "")
    if not online then return nil end
    if net.handler then
        local st, h, b = net.handler(req)
        if st then return st, h, b end
    end
    local r = net.routes[req.url]
    if not r then return 404, {}, "" end
    return r[1], r[2] or {}, r[3] or ""
end

-- Plugin ---------------------------------------------------------------------
local Login = require("blossomreads_login")
local Store = require("blossomreads_store")
local BlossomReads = dofile("blossomreads.koplugin/main.lua")

local menu_registered
local function newPlugin(doc)
    local ui = { menu = { registerToMainMenu = function(_, p) menu_registered = p end } }
    if doc then
        ui.document = { file = doc.file }
        ui.doc_props = doc.props or {}
        ui.rolling = { getLastPercent = function() return doc.pct end }
        ui.doc_settings = { readSetting = function(_, k) if k == "summary" then return doc.summary end end }
    end
    local p = BlossomReads:new{ ui = ui, path = "/plugins/blossomreads.koplugin" }
    p.transport = transport
    return p
end

local function runScheduled()
    local list = scheduled
    scheduled = {}
    for _, s in ipairs(list) do s.fn() end
end

local function signIn()
    Login.saveSession("session-id=s1", "42", "valid")
end

local function lastCard()
    for i = #shown, 1, -1 do
        if shown[i].kind == "InfoMessage" then return shown[i].text end
    end
end

local function reset()
    shown, closed, scheduled = {}, {}, {}
    -- (automatic update checks are tested on their own)
    G_reader_settings.data = { blossomreads = { auto_update_check = false } }
    online = true
    sidecars = {}
    on_disk = {}
    collections.coll = {}
    history.hist = {}
    _G.BLOSSOM_INSTALLED = false
    _G.REAL_ROOT, _G.STATS_FIRST, _G.LAST_SQL = nil, nil, nil
    resetNet()
    Login.signOut()
    Store.remove("books")
    BlossomReads._resetForTests()
end

-- Tests ----------------------------------------------------------------------
test("load: plugin registers menu and gesture actions", function()
    reset()
    local p = newPlugin()
    eq(menu_registered, p)
    assert(dispatched.blossomreads_sync and dispatched.blossomreads_open and dispatched.blossomreads_book)
end)

test("sync: Wi-Fi connect syncs changed books once; a second event within 5 min is throttled", function()
    reset()
    signIn()
    local p = newPlugin()
    p:linkBook("/b/dune.epub", { gid = "1", title = "Dune" })
    sidecars["/b/dune.epub"] = { percent_finished = 0.476, summary = { status = "reading" }, mtime = 100 }
    p:onNetworkConnected()
    eq(#scheduled, 1)
    runScheduled()
    eq(net.log, { "GET /review/list", "POST /shelf/add_to_shelf", "POST /user_status.json" })
    eq(lastCard(), "Goodreads ♡ 1 book updated")
    p:onNetworkConnected()
    eq(#scheduled, 0)
end)

test("sync: auto sync with nothing new stays silent", function()
    reset()
    signIn()
    local p = newPlugin()
    p:linkBook("/b/dune.epub", { gid = "1" })
    local s = p:runSync{ auto = true }
    eq({ s.changed, lastCard() }, { false, nil })
end)

test("sync: wake only syncs when already online", function()
    reset()
    signIn()
    local p = newPlugin()
    online = false
    p:onResume()
    eq(#scheduled, 0)
end)

test("sync: settings toggles switch the triggers off", function()
    reset()
    signIn()
    local p = newPlugin()
    p:setSetting("auto_on_wifi", false)
    p:onNetworkConnected()
    eq(#scheduled, 0)
end)

test("sync: closing a linked book pushes its live progress", function()
    reset()
    signIn()
    local p = newPlugin{ file = "/b/emma.epub", pct = 0.31, summary = { status = "reading" } }
    p:linkBook("/b/emma.epub", { gid = "2" })
    p:onCloseDocument()
    eq(#scheduled, 1)
    runScheduled()
    eq(Store.open("books"):get("/b/emma.epub").pushed_pct, 31)
end)

test("sync: closing an unlinked book or while offline does nothing", function()
    reset()
    signIn()
    local p = newPlugin{ file = "/b/new.epub", pct = 0.5 }
    p:onCloseDocument()
    online = false
    p:linkBook("/b/new.epub", { gid = "3" })
    p:onCloseDocument()
    eq(#scheduled, 0)
end)

test("sync: manual sync shows a card; sign-in page marks the session expired", function()
    reset()
    signIn()
    local p = newPlugin()
    p:linkBook("/b/dune.epub", { gid = "1" })
    sidecars["/b/dune.epub"] = { percent_finished = 0.5, mtime = 1 }
    net.routes[GR .. "/review/list"] = { 302, { Location = GR .. "/user/sign_in" } }
    net.routes[GR .. "/user/sign_in"] = { 200, {}, "form" }
    p:syncNow()
    eq(lastCard(), "Goodreads asked you to sign in again ♡")
    eq({ Login.signedIn(), Login.session().state }, { false, "expired" })
end)

test("sync: firewall block does not sign you out", function()
    reset()
    signIn()
    local p = newPlugin()
    p:linkBook("/b/dune.epub", { gid = "1" })
    sidecars["/b/dune.epub"] = { percent_finished = 0.5, mtime = 1 }
    net.routes[GR .. "/review/list"] = { 403, {}, "" }
    local s = p:runSync{}
    eq({ s.error, Login.signedIn() }, { "blocked", true })
end)

test("sync: not signed in → manual sync explains, auto sync is silent", function()
    reset()
    local p = newPlugin()
    p:runSync{ auto = true }
    eq(lastCard(), nil)
    p:runSync{}
    assert(lastCard():find("sign in"), lastCard())
end)

test("goal: shared with Blossom when installed (Goodreads goal pulled in)", function()
    reset()
    signIn()
    _G.BLOSSOM_INSTALLED = true
    G_reader_settings.data.blossom = { yearly_goal = 12, open_as = "window" }
    local p = newPlugin()
    local s = p:runSync{}
    eq(G_reader_settings.data.blossom, { yearly_goal = 24, open_as = "window" })
    eq({ p:getSetting("goal_synced"), s.goal.action }, { 24, "pull" })
    eq(p:getSetting("challenge").goal, 24)
end)

test("goal: not touched when Blossom isn't installed or sharing is off", function()
    reset()
    signIn()
    G_reader_settings.data.blossom = { yearly_goal = 12 }
    newPlugin():runSync{}
    eq(G_reader_settings.data.blossom.yearly_goal, 12)
    _G.BLOSSOM_INSTALLED = true
    local p = newPlugin()
    p:setSetting("share_goal", false)
    p:runSync{}
    eq(G_reader_settings.data.blossom.yearly_goal, 12)
end)

test("link: opening an unlinked book links it by ISBN in the background", function()
    reset()
    signIn()
    net.routes[GR .. "/book/auto_complete?format=json&q=9780441172719"] = { 200, {},
        [[ [{"bookId":44767458,"bookTitleBare":"Dune","author":{"name":"Frank Herbert"}}] ]] }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0, props = { title = "Dune", identifiers = "isbn:9780441172719" } }
    p:onReaderReady()
    runScheduled()
    eq(Store.open("books"):get("/b/dune.epub"), { gid = "44767458", title = "Dune", author = "Frank Herbert", linked = "isbn" })
    eq(lastCard(), "Found on Goodreads ♡\nDune")
end)

test("menu: iCloud-style items, status line and toggles", function()
    reset()
    local p = newPlugin()
    local items = {}
    p:addToMainMenu(items)
    local texts = {}
    for _, it in ipairs(items.blossomreads.sub_item_table) do
        texts[#texts + 1] = it.text or it.text_func()
    end
    eq(texts, { "Sync now", "Last sync: never", "Open Blossom Reads", "This book", "Sync when Wi-Fi connects",
        "Sync on wake", "Sync when closing a book", "Link books automatically", "Sync collections to shelves",
        "Collections → shelves", "Mark Read at 99%", "Send read dates and rereads", "Sign in to Goodreads",
        "Check for updates (v?)", "Check for updates automatically", "Remember password" })
    eq(items.blossomreads.sorting_hint, "tools")
    local wifi = items.blossomreads.sub_item_table[5]
    eq(wifi.checked_func(), true)
    wifi.callback()
    eq({ wifi.checked_func(), G_reader_settings.data.blossomreads.auto_on_wifi }, { false, false })
end)

test("menu: Blossom installed adds the goal toggle (12 items); status after a sync", function()
    reset()
    signIn()
    _G.BLOSSOM_INSTALLED = true
    local p = newPlugin()
    p:runSync{}
    local items = {}
    p:addToMainMenu(items)
    local list = items.blossomreads.sub_item_table
    eq(#list, 17)
    eq(list[13].text, "Share my yearly goal with Blossom")
    assert(list[2].text_func():find("^Last sync: %d%d:%d%d — goal set to 24 ♥$"), list[2].text_func())
    eq(list[14].text_func(), "Signed in as 42")
end)

test("sign-in: dialog → signed in, password remembered, menu refreshed", function()
    reset()
    net.routes[GR .. "/user/sign_in"] = { 200, {}, [[<form action="https://www.amazon.com/ap/signin"><input type="email" name="email"><input type="password" name="password"></form>]] }
    net.routes["https://www.amazon.com/ap/signin"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s9; Path=/" } }
    net.routes[GR .. "/"] = { 200, {}, "home" }
    local p = newPlugin()
    local refreshed = false
    p:signIn({ updateItems = function() refreshed = true end })
    local dialog = shown[#shown]
    eq(dialog.kind, "MultiInputDialog")
    dialog.answer = { "me@x.com", "pw" }
    dialog.buttons[1][2].callback()
    eq({ Login.signedIn(), refreshed, lastCard() }, { true, true, "Signed in to Goodreads ♡" })
    eq(Login.credentials(), { email = "me@x.com", password = "pw" })
end)

test("sign-in: verification code is asked for and submitted", function()
    reset()
    net.routes[GR .. "/user/sign_in"] = { 200, {}, [[<form action="https://www.amazon.com/ap/signin"><input type="email" name="email"><input type="password" name="password"></form>]] }
    net.routes["https://www.amazon.com/ap/signin"] = { 200, {}, [[Two-Step Verification<form action="/ap/mfa"><input name="otpCode"></form>]] }
    net.routes["https://www.amazon.com/ap/mfa"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s9; Path=/" } }
    net.routes[GR .. "/"] = { 200, {}, "home" }
    local p = newPlugin()
    p:signIn()
    shown[#shown].answer = { "me@x.com", "pw" }
    shown[#shown].buttons[1][2].callback()
    local ask = shown[#shown]
    eq(ask.kind, "InputDialog")
    ask.answer = "123456"
    ask.buttons[1][2].callback()
    eq(Login.signedIn(), true)
end)

test("sign-in: wrong password explained", function()
    reset()
    net.routes[GR .. "/user/sign_in"] = { 200, {}, [[<form action="https://www.amazon.com/ap/signin"><input type="email" name="email"><input type="password" name="password"></form>]] }
    net.routes["https://www.amazon.com/ap/signin"] = { 200, {}, "Your password is incorrect" }
    local p = newPlugin()
    p:signIn()
    shown[#shown].answer = { "me@x.com", "bad" }
    shown[#shown].buttons[1][2].callback()
    eq(lastCard(), "That email or password didn't work ☆")
end)

local function texts(w, out)
    out = out or {}
    if type(w) ~= "table" then return out end
    if type(w.text) == "string" then out[#out + 1] = w.text end
    for _, c in ipairs(w) do texts(c, out) end
    return out
end
local function textOf(w) return table.concat(texts(w), "\n") end
local function walk(w, fn)
    if type(w) ~= "table" then return end
    fn(w)
    for _, c in ipairs(w) do walk(c, fn) end
end

test("theme: independent copy — own icons folder, brand label, always a window", function()
    local Theme = require("blossomreads_theme")
    assert(Theme.dir:find("blossomreads%.koplugin$"), Theme.dir)
    local files = {}
    walk(Theme.header("My shelves", 500, function() end), function(w) if w.file then files[#files + 1] = w.file end end)
    for _, f in ipairs(files) do assert(f:find("blossomreads%.koplugin/icons/"), f) end
    assert(textOf(Theme.header("My shelves", 500)):find("Blossom Reads\nMy shelves"))
    eq(Theme.header("x", 500, nil, nil, { brand = "Other" }) ~= nil, true)
    local g = Theme.pageGeometry()
    eq({ g.window, g.outer_w, g.outer_h, g.x, g.y }, { true, 540, 704, 30, 48 })
end)

local function lastShown(kind)
    for i = #shown, 1, -1 do if shown[i].kind == kind or (kind == nil) then return shown[i] end end
end
local function findTap(w, needle)
    local found
    walk(w, function(x)
        if not found and x.callback and x.ges_events and textOf(x):find(needle, 1, true) then found = x end
    end)
    return found
end

test("home: signed out shows a sign-in button", function()
    reset()
    local View = require("blossomreads_view")
    local home = View.show(newPlugin())
    assert(textOf(home):find("Sign in to Goodreads ♡"), textOf(home))
    eq(#net.log, 0)
end)

test("home: popup geometry, this book, challenge with both counts, shelves; stale data refreshed", function()
    reset()
    signIn()
    net.routes[GR .. "/review/list"] = { 200, {}, REVIEW_LIST .. [[<script>new ShelfChooser("x", 0, ["read","currently-reading","to-read","cozy"], {})</script>
        <a href="?shelf=read">Read (12)</a>]] }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.47, props = { title = "Dune" } }
    p:linkBook("/b/dune.epub", { gid = "1", title = "Dune", author = "Frank Herbert" })
    p.ui.blossom = { loadYear = function() return { finished = 7 } end }
    local home = require("blossomreads_view").show(p)
    eq({ home.dimen.w, home.dimen.h, home.covers_fullscreen }, { 540, 704, false })
    eq(net.log, { "GET /readingchallenges/goals/data", "GET /review/list" })
    local t = textOf(home)
    for _, want in ipairs({ "My Goodreads", "Dune", "Frank Herbert", "Currently Reading · 47%", "9", " of 24 books",
        "Blossom counted 7 ❀", "Read  12", "Currently Reading", "cozy", "Find a book" }) do
        assert(t:find(want, 1, true), want .. " missing in:\n" .. t)
    end
    -- reopening soon after doesn't fetch again
    net.log = {}
    require("blossomreads_view").show(p)
    eq(net.log, {})
end)

test("home: tap outside the window closes it", function()
    reset()
    local home = require("blossomreads_view").show(newPlugin())
    local n = #closed
    home:onTapOutside(nil, { pos = { x = 5, y = 5 } })
    eq(#closed, n + 1)
    home:onTapOutside(nil, { pos = { x = 300, y = 400 } })
    eq(#closed, n + 1)
end)

test("home: editing the goal sets Goodreads and Blossom together", function()
    reset()
    signIn()
    _G.BLOSSOM_INSTALLED = true
    G_reader_settings.data.blossom = { yearly_goal = 12 }
    net.routes[GR .. "/readingchallenges/annual"] = { 200, {}, [[<input type="hidden" name="anti-csrftoken-a2z" value="W">]] }
    net.routes[GR .. "/readingchallenges/updateGoal?newGoal=30"] = { 200, {}, "{}" }
    local p = newPlugin()
    p:setSetting("challenge", { goal = 24, read = 9, at = os.time() })
    p:setSetting("shelves", { list = {}, at = os.time() })
    local home = require("blossomreads_view").show(p)
    home:editGoal(24)
    local spin = lastShown("SpinWidget")
    spin.callback({ value = 30 })
    eq({ G_reader_settings.data.blossom.yearly_goal, p:getSetting("goal_synced"), p:getSetting("challenge").goal }, { 30, 30, 30 })
    assert(textOf(home):find(" of 30 books", 1, true))
end)

test("home: pace wording", function()
    local View = require("blossomreads_view")
    local mid = os.time{ year = 2026, month = 7, day = 2, hour = 12 } -- about half way
    eq(View.pace(12, 24, 182, mid), "right on track ❀")
    eq(View.pace(15, 24, 182, mid), "3 books ahead ♡")
    eq(View.pace(11, 24, 182, mid), "1 book behind — you've got this ☆")
    eq(View.pace(24, 24, 182, mid), "Goal reached! ♥")
    eq(View.pace(0, 0, 182, mid), "no challenge yet ♡")
end)

test("book card: shelf picked by hand is sent and pinned; rating with hearts", function()
    reset()
    signIn()
    net.routes[GR .. "/review/rate/1?no_lightbox=true&queue=false&stars_click=true&rating=4"] = { 200, {}, "" }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.2 }
    p:linkBook("/b/dune.epub", { gid = "1", title = "Dune", author = "Frank Herbert" })
    local card = require("blossomreads_book").show(p, "/b/dune.epub")
    assert(textOf(card):find("Read 20%", 1, true), textOf(card))
    card:setShelf("to-read")
    local e = Store.open("books"):get("/b/dune.epub")
    eq({ e.pushed_shelf, e.pinned_shelf }, { "to-read", "to-read" })
    assert(net.log[#net.log] == "POST /shelf/add_to_shelf", net.log[#net.log])
    card:rate(4)
    eq(Store.open("books"):get("/b/dune.epub").rating, 4)
    assert(textOf(card):find("♥\n♥\n♥\n♥\n♡", 1, true), textOf(card))
    -- the next sync keeps the hand-picked shelf (no Currently Reading), progress still goes up
    net.log = {}
    p:runSync{}
    eq(net.log, { "GET /review/list", "POST /user_status.json" }) -- no goal step: Blossom not installed
end)

test("book card: a failed shelf write changes nothing locally", function()
    reset()
    signIn()
    net.routes[GR .. "/shelf/add_to_shelf"] = { 500, {}, "" }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.2 }
    p:linkBook("/b/dune.epub", { gid = "1", title = "Dune" })
    local card = require("blossomreads_book").show(p, "/b/dune.epub")
    card:setShelf("read")
    eq(Store.open("books"):get("/b/dune.epub").pushed_shelf, nil)
    eq(lastCard(), "Goodreads didn't answer properly ☆")
end)

test("book card: not linked → Find on Goodreads links a sure match; Unlink", function()
    reset()
    signIn()
    net.routes[GR .. "/book/auto_complete?format=json&q=9780441172719"] = { 200, {}, [[ [{"bookId":7,"bookTitleBare":"Dune","author":{"name":"Frank Herbert"}}] ]] }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.2, props = { title = "Dune", identifiers = "isbn:9780441172719" } }
    local card = require("blossomreads_book").show(p, "/b/dune.epub")
    assert(textOf(card):find("Not linked to Goodreads yet ♡", 1, true))
    card:find()
    eq(Store.open("books"):get("/b/dune.epub").gid, "7")
    assert(textOf(card):find("Frank Herbert", 1, true))
    card:unlink()
    eq(Store.open("books"):get("/b/dune.epub"), nil)
end)

local function shelfRow(i)
    return string.format([[<tr class="bookalike review"><td><img id="cover_%d" src="https://i.gr-assets.com/c%d.jpg"></td>
      <td><a title="Book %d" href="/book/show/%d-x">Book %d</a></td>
      <td class="field author"><div class="value"><a href="/a">Author %d</a></div></td></tr>]], i, i, i, i, i, i)
end

test("list: a shelf, paged locally then from Goodreads; covers fetched after showing", function()
    reset()
    signIn()
    local page1, page2 = {}, {}
    for i = 1, 12 do page1[#page1 + 1] = shelfRow(i) end
    for i = 13, 14 do page2[#page2 + 1] = shelfRow(i) end
    net.routes[GR .. "/review/list?shelf=to-read&per_page=30&page=1&view=table"] = { 200, {}, table.concat(page1) .. '<a rel="next">' }
    net.routes[GR .. "/review/list?shelf=to-read&per_page=30&page=2&view=table"] = { 200, {}, table.concat(page2) }
    for i = 1, 14 do net.routes["https://i.gr-assets.com/c" .. i .. ".jpg"] = { 200, {}, string.rep("J", 300) } end
    local p = newPlugin()
    local list = require("blossomreads_list").shelf(p, "to-read")
    local per = list.per_page
    assert(per >= 3 and per < 12, "per page " .. per)
    eq(list.pages, math.ceil(12 / per) + 1)
    assert(textOf(list):find("Book 1\nAuthor 1", 1, true))
    -- covers for the visible rows only, fetched after the page is up
    net.log = {}
    runScheduled()
    eq(#net.log, per)
    local Covers = require("blossomreads_covers")
    assert(Covers.cached("1") and not Covers.cached(tostring(per + 1)))
    -- walk to the end: the next Goodreads page is loaded once, and fills the last page first
    while list.page < math.ceil(12 / per) do list:onNextPage() end
    local last = list.page
    list:onNextPage()
    eq({ #list.items, list.more }, { 14, nil })
    local shown_now = textOf(list)
    eq({ list.page, shown_now:find("Book 13", 1, true) ~= nil, list.pages }, { last, true, math.ceil(14 / per) })
    list:onNextPage()
    eq(list.page, math.ceil(14 / per))
end)

test("list: tapping a search result adds it to a shelf", function()
    reset()
    signIn()
    net.routes[GR .. "/book/auto_complete?format=json&q=emma"] = { 200, {}, [[ [{"bookId":5,"bookTitleBare":"Emma","author":{"name":"Jane Austen"}}] ]] }
    local p = newPlugin()
    p:setSetting("shelves", { list = { { slug = "cozy", custom = true } }, at = os.time() })
    local list = require("blossomreads_list").search(p, "emma")
    assert(textOf(list):find("Emma\nJane Austen", 1, true))
    list:pick(list.items[1])
    local dialog = lastShown("ButtonDialog")
    local labels = {}
    for _, row in ipairs(dialog.buttons) do labels[#labels + 1] = row[1].text end
    eq(labels, { "Want to Read", "Currently Reading", "Read", "Did Not Finish", "cozy", "Cancel" })
    net.log = {}
    dialog.buttons[5][1].callback()
    eq(net.log, { "GET /review/list", "POST /shelf/add_to_shelf" })
    eq(lastCard(), "Added to cozy ♡")
end)

test("list: no results / empty shelf messages", function()
    reset()
    signIn()
    net.routes[GR .. "/book/auto_complete?format=json&q=zzz"] = { 200, {}, "[]" }
    local list = require("blossomreads_list").search(newPlugin(), "zzz")
    assert(textOf(list):find("No books found ☆", 1, true))
end)

test("book card: 'Find another' lets you pick from the matches", function()
    reset()
    signIn()
    net.routes[GR .. "/book/auto_complete?format=json&q=Dune%20Frank%20Herbert"] = { 200, {},
        [[ [{"bookId":1,"bookTitleBare":"Dune","author":{"name":"Frank Herbert"}},{"bookId":2,"bookTitleBare":"Dune Messiah","author":{"name":"Frank Herbert"}}] ]] }
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.2, props = { title = "Dune", authors = "Frank Herbert" } }
    p:linkBook("/b/dune.epub", { gid = "1", title = "Dune" })
    local card = require("blossomreads_book").show(p, "/b/dune.epub")
    card:find(true)
    local picker = shown[#shown]
    eq(picker.title, "Which book is it?")
    assert(textOf(picker):find("85% match", 1, true), textOf(picker))
    picker:pick(picker.items[2])
    eq(Store.open("books"):get("/b/dune.epub").gid, "2")
    assert(textOf(card):find("Dune Messiah", 1, true))
end)

test("sign-in: picture puzzle is shown, then the answer asked for", function()
    reset()
    net.routes[GR .. "/user/sign_in"] = { 200, {}, [[<form action="https://www.amazon.com/ap/signin"><input type="email" name="email"><input type="password" name="password"></form>]] }
    net.routes["https://www.amazon.com/ap/signin"] = { 200, {}, [[<img src="https://opfcaptcha.amazon.com/p.jpg"><form action="/ap/cvf"><input type="text" name="cvf_captcha_input"></form>]] }
    net.routes["https://opfcaptcha.amazon.com/p.jpg"] = { 200, {}, "JPEGDATA" }
    net.routes["https://www.amazon.com/ap/cvf"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s9" } }
    net.routes[GR .. "/"] = { 200, {}, "home" }
    local p = newPlugin()
    p:signIn()
    shown[#shown].answer = { "me@x.com", "pw" }
    shown[#shown].buttons[1][2].callback()
    local viewer = lastShown("ImageViewer")
    local f = io.open(viewer.file, "rb")
    eq(f:read("*a"), "JPEGDATA")
    f:close()
    viewer:onCloseWidget()
    runScheduled()
    local ask = lastShown("InputDialog")
    ask.answer = "AB12"
    ask.buttons[1][2].callback()
    eq(Login.signedIn(), true)
end)

test("home: no 'Blossom counted' line when Blossom isn't loaded", function()
    reset()
    signIn()
    local p = newPlugin()
    p:setSetting("challenge", { goal = 24, read = 9, at = os.time() })
    p:setSetting("shelves", { list = {}, at = os.time() })
    local home = require("blossomreads_view").show(p)
    assert(not textOf(home):find("Blossom counted", 1, true))
    assert(textOf(home):find("Tap to gather your shelves", 1, true))
end)

test("gestures: Dispatcher events open screens and sync", function()
    reset()
    signIn()
    local p = newPlugin{ file = "/b/dune.epub", pct = 0.1 }
    p:setSetting("challenge", { goal = 24, read = 9, at = os.time() })
    p:setSetting("shelves", { list = {}, at = os.time() })
    local n = #shown
    p:onBlossomReadsOpen()
    p:onBlossomReadsBook()
    eq({ shown[n + 1].title, shown[n + 2].title }, { "My Goodreads", "This book" })
    p:onBlossomReadsSync()
    eq(lastCard(), "Up to date ♡")
end)

-- Collections → shelves (made-up books)
local A = "/mnt/us/Books/Juniper Hale/(2) Moonlit Orchard - Juniper Hale.epub"
local B = "/mnt/us/Books/Paper Lanterns - Ada Penrose.epub"
local C = "/mnt/us/Books/Seaglass Summer - Nora Pike.epub"
local function libraryFixture()
    on_disk[A], on_disk[B], on_disk[C] = true, true, true
    collections.coll = { ["To Be Read"] = { [A] = {}, [B] = {} }, ["favorites"] = { [B] = {} } }
    history.hist = { { file = C } }
    sidecars[C] = { percent_finished = 0.4, mtime = 5, doc_props = { title = "Seaglass Summer", authors = "Nora Pike" } }
    local function hit(id, title, author)
        return { 200, {}, string.format('[{"bookId":%d,"bookTitleBare":"%s","author":{"name":"%s"}}]', id, title, author) }
    end
    net.routes[GR .. "/book/auto_complete?format=json&q=Moonlit%20Orchard%20Juniper%20Hale"] = hit(101, "Moonlit Orchard", "Juniper Hale")
    net.routes[GR .. "/book/auto_complete?format=json&q=Paper%20Lanterns%20Ada%20Penrose"] = hit(102, "Paper Lanterns", "Ada Penrose")
    net.routes[GR .. "/book/auto_complete?format=json&q=Seaglass%20Summer%20Nora%20Pike"] = hit(103, "Seaglass Summer", "Nora Pike")
end
local function posts()
    local out = {}
    for _, l in ipairs(net.log) do if l:find("^POST") then out[#out + 1] = l end end
    return out
end

test("collections: Sync now links unlinked books and mirrors collections onto shelves", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin()
    local s = p:runSync{}
    eq(s.linked, 3)
    local b = Store.open("books").data
    eq({ b[A].gid, b[B].gid, b[C].gid }, { "101", "102", "103" })
    eq({ b[A].pushed_shelf, b[B].pushed_shelf, b[B].collections_sent, b[C].pushed_shelf, b[C].pushed_pct },
        { "to-read", "to-read", { "favorites" }, "currently-reading", 40 })
    eq(#posts(), 5) -- A to-read, B to-read + favorites, C currently-reading + 40%
    eq(lastCard(), "Goodreads ♡ 3 books updated · 3 books linked")
end)

test("collections: a second sync sends nothing", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin()
    p:runSync{}
    net.log = {}
    p:runSync{}
    eq(posts(), {})
    eq(lastCard(), "Up to date ♡")
end)

test("collections: leaving favorites takes the book off the Goodreads shelf", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin()
    p:runSync{}
    collections.coll.favorites = {}
    net.log = {}
    local bodies = {}
    local orig = p.transport
    p.transport = function(req) if req.method == "POST" then bodies[#bodies + 1] = req.body end return orig(req) end
    p:runSync{}
    eq(#bodies, 1)
    assert(bodies[1]:find("a=remove") and bodies[1]:find("name=favorites") and bodies[1]:find("book_id=102"), bodies[1])
    eq(Store.open("books"):get(B).collections_sent, nil)
end)

test("collections: starting a TBR book moves it to Currently Reading", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin()
    p:runSync{}
    sidecars[A] = { percent_finished = 0.05, mtime = 9 }
    net.log = {}
    p:runSync{}
    eq(#posts(), 2)
    eq(Store.open("books"):get(A).pushed_shelf, "currently-reading")
end)

test("collections: a book with no match isn't searched again for a week", function()
    reset()
    signIn()
    local X = "/mnt/us/Books/Unknown Thing.epub"
    on_disk[X] = true
    collections.coll = { ["To Be Read"] = { [X] = {} } }
    net.routes[GR .. "/book/auto_complete?format=json&q=Unknown%20Thing"] = { 200, {}, "[]" }
    local p = newPlugin()
    p:runSync{}
    assert(Store.open("books"):get(X).unmatched_at)
    net.log = {}
    p:runSync{}
    eq(net.log, {}) -- no search, and nothing else to send
end)

test("collections: at most 8 books are linked per automatic sync", function()
    reset()
    signIn()
    local coll = {}
    for i = 1, 11 do
        local f = string.format("/mnt/us/Books/Book %02d - Some Author.epub", i)
        on_disk[f], coll[f] = true, {}
        net.routes[GR .. string.format("/book/auto_complete?format=json&q=Book%%20%02d%%20Some%%20Author", i)] = { 200, {},
            string.format('[{"bookId":%d,"bookTitleBare":"Book %02d","author":{"name":"Some Author"}}]', 200 + i, i) }
    end
    collections.coll = { ["To Be Read"] = coll }
    local p = newPlugin()
    eq(p:runSync{ auto = true }.linked, 8) -- automatic syncs stay short
    eq(p:runSync{ auto = true }.linked, 3)
end)

test("collections: Sync now links up to 25 books at once", function()
    reset()
    signIn()
    local coll = {}
    for i = 1, 11 do
        local f = string.format("/mnt/us/Books/Book %02d - Some Author.epub", i)
        on_disk[f], coll[f] = true, {}
        net.routes[GR .. string.format("/book/auto_complete?format=json&q=Book%%20%02d%%20Some%%20Author", i)] = { 200, {},
            string.format('[{"bookId":%d,"bookTitleBare":"Book %02d","author":{"name":"Some Author"}}]', 200 + i, i) }
    end
    collections.coll = { ["To Be Read"] = coll }
    eq(newPlugin():runSync{}.linked, 11)
end)

test("collections: 'Don't sync' and the master toggle are respected", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin()
    p:setCollectionMap("favorites", "off")
    p:runSync{}
    eq(Store.open("books"):get(B).collections_sent, nil)
    reset()
    signIn()
    libraryFixture()
    p = newPlugin()
    p:setSetting("sync_collections", false)
    local s = p:runSync{}
    eq(s.linked, 1) -- only the history book; collections ignored
    eq(Store.open("books"):get(A), nil)
end)

test("collections: closing a book doesn't run linking (stays quick)", function()
    reset()
    signIn()
    libraryFixture()
    local p = newPlugin{ file = C, pct = 0.5 }
    p:linkBook(C, { gid = "103" })
    p:onCloseDocument()
    runScheduled()
    for _, l in ipairs(net.log) do assert(not l:find("auto_complete"), l) end
end)

test("menu: Collections → shelves lists each collection and its shelf; choices change it", function()
    reset()
    collections.coll = { ["To Be Read"] = {}, ["favorites"] = {}, ["Cozy Autumn"] = {} }
    local p = newPlugin()
    local items = {}
    p:addToMainMenu(items)
    local entry
    for _, it in ipairs(items.blossomreads.sub_item_table) do
        if it.text == "Collections → shelves" then entry = it end
    end
    local sub = entry.sub_item_table_func()
    local lines = {}
    for _, it in ipairs(sub) do lines[#lines + 1] = it.text_func() end
    eq(lines, { "Cozy Autumn → cozy autumn", "To Be Read → Want to Read", "favorites → favorites" })
    local choices = sub[3].sub_item_table_func()
    eq(choices[1].checked_func(), true) -- Automatic
    choices[6].callback() -- Don't sync
    eq(sub[3].text_func(), "favorites → not synced")
    choices[7].callback() -- Another shelf…
    local ask = lastShown("InputDialog")
    ask.answer = "Comfort Reads"
    ask.buttons[1][2].callback()
    eq(sub[3].text_func(), "favorites → comfort reads")
    eq(Login.pending(), false)
end)

-- Read dates, rereads, finished books, editions (fake Goodreads keeps reading sessions)
local Fixtures = require("blossomreads_fixtures")
local function readingGoodreads()
    local gr = { sessions = {}, shelvings = {}, saves = 0 }
    net.handler = function(req)
        local gid = req.url:match("/review/edit/(%d+)$")
        if gid and req.method == "GET" then
            return 200, {}, Fixtures.reviewPage{ gid = gid, sessions = gr.sessions[gid] or {}, shelvings = gr.shelvings[gid] }
        end
        if gid and req.method == "POST" then
            gr.saves = gr.saves + 1
            gr.sessions[gid] = Fixtures.applySave(req.body)
            return 200, {}, "0:{}"
        end
        if req.url:find("/_next/static/chunks/") then
            return 200, {}, req.url:find("5305%-b%.js$") and Fixtures.ACTION_JS or ""
        end
        if req.url:find("/shelf/add_to_shelf") and req.body:find("name=read&") then
            local book = req.body:match("book_id=(%d+)")
            gr.sessions[book] = gr.sessions[book] or {}
            if #gr.sessions[book] == 0 then
                gr.sessions[book][1] = { id = "kca://reading_session/auto" .. book, bookId = "kca://book/B" .. book, state = "COMPLETED" }
            end
        end
    end
    return gr
end
local function ended(s) local d = s and s.endedDate; return d and string.format("%d-%02d-%02d", d.year, d.month, d.day) end
local function started(s) local d = s and s.startedDate; return d and string.format("%d-%02d-%02d", d.year, d.month, d.day) end

test("dates: Sync now marks a finished book Read with KOReader's finish date and the stats start date", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    _G.STATS_FIRST = os.time{ year = 2026, month = 8, day = 20, hour = 9 }
    on_disk[SETTINGS .. "/statistics.sqlite3"] = true
    local p = newPlugin()
    p:linkBook(C, { gid = "500" })
    sidecars[C] = { percent_finished = 1, summary = { status = "complete", modified = "2026-09-02" }, mtime = 5 }
    local s = p:runSync{}
    eq({ #gr.sessions["500"], ended(gr.sessions["500"][1]), started(gr.sessions["500"][1]) }, { 1, "2026-09-02", "2026-08-20" })
    eq(Store.open("books"):get(C).reads_sent, { "2026-09-02" })
    eq(lastCard(), "Goodreads ♡ 1 book updated · 1 read date added")
    assert(_G.LAST_SQL:find("b.md5 = 'abc123'", 1, true), _G.LAST_SQL)
    -- the save action id is remembered in settings for next time
    eq(p:getSetting("review_action").id, "6036dfbeef")
    net.log = {}
    p:runSync{}
    for _, l in ipairs(net.log) do assert(not l:find("review/edit"), l) end
end)

test("dates: Goodreads already has a date for this book (another edition) → left alone", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    gr.sessions["500"] = { { id = "s-hc", bookId = "kca://book/HC", state = "COMPLETED", endedDate = { year = 2025, month = 11, day = 18 } } }
    local p = newPlugin()
    p:linkBook(C, { gid = "500" })
    Store.open("books"):get(C)
    local store = Store.open("books"); local e = store:get(C); e.pushed_shelf = "read"; store:set(C, e); store:flush()
    sidecars[C] = { percent_finished = 0.13, summary = { status = "complete", modified = "2025-11-18" }, mtime = 5 }
    p:runSync{}
    eq(gr.saves, 0)
    eq(Store.open("books"):get(C).reads_sent, { "2025-11-18" })
end)

test("rereads: reading a finished book again, then finishing it, adds a reread on Goodreads", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    gr.sessions["500"] = { { id = "s1", bookId = "kca://book/B500", state = "COMPLETED", endedDate = { year = 2025, month = 11, day = 18 } } }
    on_disk[SETTINGS .. "/statistics.sqlite3"] = true
    local p = newPlugin()
    local store = Store.open("books")
    store:set(C, { gid = "500", pushed_shelf = "read", reads_sent = { "2025-11-18" }, read_pct = 100 })
    store:flush()
    sidecars[C] = { percent_finished = 0.05, summary = { status = "reading" }, mtime = 5 }
    p:runSync{}
    eq(Store.open("books"):get(C).rereading, true)
    sidecars[C] = { percent_finished = 1, summary = { status = "complete", modified = "2026-10-01" }, mtime = 9 }
    _G.STATS_FIRST = os.time{ year = 2026, month = 9, day = 12, hour = 9 }
    p:runSync{}
    eq({ #gr.sessions["500"], ended(gr.sessions["500"][2]), started(gr.sessions["500"][2]) }, { 2, "2026-10-01", "2026-09-12" })
    assert(_G.LAST_SQL:find("start_time > " .. os.time{ year = 2025, month = 11, day = 18, hour = 23, min = 59 }, 1, true), _G.LAST_SQL)
    eq(Store.open("books"):get(C).reads_sent, { "2025-11-18", "2026-10-01" })
end)

test("edition: a new link uses the edition you already have on a shelf", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    gr.shelvings["103"] = { { book = { id = "kca://book/HC", legacyId = 777 }, shelf = { name = "read" }, readingSessions = {} } }
    libraryFixture()
    collections.coll = {}
    local p = newPlugin()
    p:runSync{}
    eq({ Store.open("books"):get(C).gid, Store.open("books"):get(C).linked }, { "777", "edition" })
end)

test("finished books: Sync now finds finished books anywhere in the library and dates them", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    local root = os.tmpname()
    os.remove(root)
    os.execute('mkdir -p "' .. root .. '/Books/Series/Lantern Light - Ada Penrose.sdr"')
    local book = root .. "/Books/Series/Lantern Light - Ada Penrose.epub"
    io.open(book, "w"):close()
    local meta = io.open(root .. "/Books/Series/Lantern Light - Ada Penrose.sdr/metadata.epub.lua", "w")
    meta:write('return { ["summary"] = { ["status"] = "complete", ["modified"] = "2025-06-30" }, ["percent_finished"] = 1 }')
    meta:close()
    _G.REAL_ROOT = root
    G_reader_settings.data.home_dir = root .. "/Books"
    sidecars[book] = { percent_finished = 1, summary = { status = "complete", modified = "2025-06-30" }, mtime = 3 }
    net.routes[GR .. "/book/auto_complete?format=json&q=Lantern%20Light%20Ada%20Penrose"] = { 200, {},
        '[{"bookId":900,"bookTitleBare":"Lantern Light","author":{"name":"Ada Penrose"}}]' }
    local p = newPlugin()
    local s = p:runSync{}
    eq(s.linked, 1)
    eq({ Store.open("books"):get(book).pushed_shelf, Store.open("books"):get(book).reads_sent }, { "read", { "2025-06-30" } })
    eq(ended(gr.sessions["900"][1]), "2025-06-30")
    -- automatic syncs don't scan the library
    Store.remove("books")
    local auto = p:runSync{ auto = true }
    eq(auto.linked, 0)
    os.execute('rm -rf "' .. root .. '"')
end)

test("finished books: an automatic sync also looks at books that were never synced", function()
    reset()
    signIn()
    readingGoodreads()
    local p = newPlugin()
    p:linkBook(C, { gid = "500" })
    sidecars[C] = { percent_finished = 1, summary = { status = "complete", modified = "2026-09-02" }, mtime = 1 }
    p:setSetting("last_sync", { time = 100 }) -- the .sdr (mtime 1) is older than the last sync
    p:onNetworkConnected()
    runScheduled()
    eq(Store.open("books"):get(C).pushed_shelf, "read")
end)

test("dates: 'Send read dates and rereads' off → no review pages are touched", function()
    reset()
    signIn()
    local gr = readingGoodreads()
    local p = newPlugin()
    p:setSetting("send_dates", false)
    p:linkBook(C, { gid = "500" })
    sidecars[C] = { percent_finished = 1, summary = { status = "complete", modified = "2026-09-02" }, mtime = 5 }
    p:runSync{}
    eq(gr.saves, 0)
    for _, l in ipairs(net.log) do assert(not l:find("review/edit"), l) end
end)

test("finished books: automatic syncs scan the library once a day", function()
    reset()
    signIn()
    readingGoodreads()
    local root = os.tmpname()
    os.remove(root)
    os.execute('mkdir -p "' .. root .. '/Books/Old Stories - Ada Penrose.sdr"')
    local book = root .. "/Books/Old Stories - Ada Penrose.epub"
    io.open(book, "w"):close()
    local meta = io.open(root .. "/Books/Old Stories - Ada Penrose.sdr/metadata.epub.lua", "w")
    meta:write('return { ["summary"] = { ["status"] = "complete", ["modified"] = "2025-03-01" } }')
    meta:close()
    _G.REAL_ROOT = root
    G_reader_settings.data.home_dir = root .. "/Books"
    net.routes[GR .. "/book/auto_complete?format=json&q=Old%20Stories"] = { 200, {}, '[{"bookId":901,"bookTitleBare":"Old Stories","author":{"name":"Ada Penrose"}}]' }
    local p = newPlugin()
    p:setSetting("last_scan", os.time() - 3600) -- scanned an hour ago
    eq(p:runSync{ auto = true }.linked, 0)
    p:setSetting("last_scan", os.time() - 25 * 3600) -- over a day ago
    eq(p:runSync{ auto = true }.linked, 1)
    assert(os.time() - p:getSetting("last_scan") < 5)
    os.execute('rm -rf "' .. root .. '"')
end)

test("linking: KOReader's own files and non-books in history are never searched", function()
    reset()
    signIn()
    local help = "/mnt/us/koreader/help/quickstart-en-v2025.08.html"
    local notes = "/mnt/us/Books/notes.json"
    on_disk[help], on_disk[notes] = true, true
    history.hist = { { file = help }, { file = notes } }
    newPlugin():runSync{}
    for _, l in ipairs(net.log) do assert(not l:find("auto_complete"), l) end
    eq({ Store.open("books"):get(help), Store.open("books"):get(notes) }, {})
end)

test("linking: books missed by the older matching get one fresh try", function()
    reset()
    signIn()
    local X = "/mnt/us/Books/Unknown Thing.epub"
    on_disk[X] = true
    history.hist = { { file = X } }
    local store = Store.open("books")
    store:set(X, { unmatched_at = os.time() - 3600 }) -- recorded by the old version (no unmatched_v)
    store:flush()
    net.routes[GR .. "/book/auto_complete?format=json&q=Unknown%20Thing"] = { 200, {}, "[]" }
    local p = newPlugin()
    p:runSync{}
    local tried = false
    for _, l in ipairs(net.log) do if l:find("auto_complete") then tried = true end end
    eq({ tried, Store.open("books"):get(X).unmatched_v }, { true, 2 })
    net.log = {}
    p:runSync{}
    for _, l in ipairs(net.log) do assert(not l:find("auto_complete"), l) end
end)

-- Updates
local RELEASES_URL = "https://api.github.com/repos/shgmacha/koreader-plugins/releases?per_page=20"
local function releases(version)
    return { 200, {}, string.format([[ [{"tag_name":"blossomreads-v%s","draft":false,"prerelease":false,"assets":[
        {"name":"blossomreads.koplugin.zip","browser_download_url":"https://x/b.zip"}]}] ]], version) }
end

test("updates: the menu shows this copy's version (from _meta.lua)", function()
    reset()
    local p = newPlugin()
    p.path = "blossomreads.koplugin"
    local items = {}
    p:addToMainMenu(items)
    local found
    for _, it in ipairs(items.blossomreads.sub_item_table) do
        if it.text_func and it.text_func():find("^Check for updates %(") then found = it.text_func() end
    end
    eq(found, "Check for updates (v1.1.0)")
end)

test("updates: Check for updates says when you're up to date, or why it couldn't check", function()
    reset()
    local p = newPlugin()
    p._version = "1.1.0"
    net.routes[RELEASES_URL] = releases("1.1.0")
    p:checkForUpdates()
    eq(lastCard(), "You have the latest Blossom Reads (v1.1.0) ♡")
    online = false
    p:checkForUpdates()
    eq(lastCard(), "Couldn't reach GitHub — check Wi-Fi ☆")
end)

test("updates: a newer release is offered; Update installs it and offers a restart", function()
    reset()
    local p = newPlugin()
    p._version, p.path = "1.1.0", "/plugins/blossomreads.koplugin"
    net.routes[RELEASES_URL] = releases("1.2.0")
    local Update = require("blossomreads_update")
    local real = Update.install
    local installed
    Update.install = function(info, dir) installed = { info.version, dir }; return info.version end
    p:checkForUpdates()
    local ask = lastShown("ConfirmBox")
    eq(ask.text, "Blossom Reads v1.2.0 is ready ♡\nYou have v1.1.0. Update now?")
    ask.ok_callback()
    Update.install = real
    eq(installed, { "1.2.0", "/plugins/blossomreads.koplugin" })
    local restart = lastShown("ConfirmBox")
    eq(restart.text, "Updated to v1.2.0 ♡\nRestart KOReader now to use it?")
    _G.RESTARTED = nil
    restart.ok_callback()
    eq(_G.RESTARTED, true)
end)

test("updates: a failed install says why and keeps the current version", function()
    reset()
    local p = newPlugin()
    p._version, p.path = "1.1.0", "/plugins/blossomreads.koplugin"
    local Update = require("blossomreads_update")
    local real = Update.install
    Update.install = function() return nil, "checksum" end
    p:installUpdate({ version = "1.2.0" })
    Update.install = real
    eq(lastCard(), "The download didn't check out, so nothing was changed ☆")
end)

test("updates: checked automatically once a day on Wi-Fi; only asks, never installs by itself", function()
    reset()
    local p = newPlugin()
    p._version = "1.1.0"
    p:setSetting("auto_update_check", true)
    p:setSetting("auto_on_wifi", false)
    net.routes[RELEASES_URL] = releases("1.2.0")
    p:onNetworkConnected()
    runScheduled()
    eq(lastShown("ConfirmBox").text, "Blossom Reads v1.2.0 is ready ♡\nYou have v1.1.0. Update now?")
    local n = #shown
    p:onNetworkConnected() -- same day: no second check
    eq(#scheduled, 0)
    p:setSetting("last_update_check", os.time() - 25 * 3600)
    net.routes[RELEASES_URL] = releases("1.1.0")
    p:onNetworkConnected()
    runScheduled()
    eq(#shown, n) -- up to date: stays quiet
end)

test("updates: turning automatic checks off stops them", function()
    reset()
    local p = newPlugin()
    p:setSetting("auto_on_wifi", false)
    p:onNetworkConnected()
    eq(#scheduled, 0)
end)

H.done()
