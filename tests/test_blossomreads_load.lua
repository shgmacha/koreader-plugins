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
local sidecars = {} -- file -> { percent_finished, summary, mtime }

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
    ["libs/libkoreader-lfs"] = { attributes = function(p, what)
        if p:find("blossom%.koplugin$") then return _G.BLOSSOM_INSTALLED and "directory" or nil end
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
    G_reader_settings.data = {}
    online = true
    sidecars = {}
    _G.BLOSSOM_INSTALLED = false
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
        "Sync on wake", "Sync when closing a book", "Link books automatically", "Mark Read at 99%",
        "Sign in to Goodreads", "Remember password" })
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
    eq(#list, 12)
    eq(list[10].text, "Share my yearly goal with Blossom")
    assert(list[2].text_func():find("^Last sync: %d%d:%d%d — goal set to 24 ♥$"), list[2].text_func())
    eq(list[11].text_func(), "Signed in as 42")
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
    eq(lastCard(), "Up to date ❀")
end)

H.done()
