-- Loads the plugin and builds every dashboard page against stubbed KOReader
-- modules, to catch require / nil-index / wiring mistakes before a device does.
local H = require("tests.harness")
local test, eq = H.test, H.eq
local ffi = require("ffi")

-- Widget stubs -------------------------------------------------------------
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
        if self.dimen and self.dimen.h then return { w = self.dimen.w, h = self.dimen.h } end
        if self.width and self.height then return { w = self.width, h = self.height } end
        if self.text then return { w = #self.text * 8, h = 20 } end
        local w, h = 0, 0
        for _, c in ipairs(self) do
            local s = c.getSize and c:getSize() or { w = c.width or 0, h = 0 }
            if self.kind == "VerticalGroup" then
                w, h = math.max(w, s.w), h + s.h
            else
                w, h = w + s.w, math.max(h, s.h)
            end
        end
        return { w = w, h = h }
    end
    function C:free()
        self.freed = true
        for _, c in ipairs(self) do if type(c) == "table" and c.free then c:free() end end
    end
    return C
end

local shown, closed, dirty = {}, {}, {}
local dispatched
local fs = {}          -- path -> true for files that "exist"
local db = {}          -- fake database behaviour
local settings_dir = "/kosettings"

local stubs = {
    ["ffi/blitbuffer"] = { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, Color8 = function(v) return v end },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["ui/size"] = { padding = { default = 5 }, border = { thin = 1 }, radius = { window = 8 } },
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
        setDirty = function(_, w, mode) table.insert(dirty, mode) end,
        forceRePaint = function() end,
    },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
    ["logger"] = { warn = function() end, dbg = function() end },
    ["datastorage"] = { getSettingsDir = function() return settings_dir end },
    ["dispatcher"] = { registerAction = function(_, id, def) dispatched = { id = id, def = def } end },
    ["libs/libkoreader-lfs"] = { attributes = function(p) return fs[p] and "file" or nil end },
    ["readhistory"] = { hist = {} },
    ["docsettings"] = {
        open = function(_, file)
            return { readSetting = function() return db.sidecar_md5 and db.sidecar_md5[file] end }
        end,
    },
    ["util"] = { partialMD5 = function(file) return "md5:" .. file end },
    ["lua-ljsqlite3/init"] = {
        open = function(path)
            if db.open_error then error(db.open_error) end
            db.opened, db.closed = (db.opened or 0) + 1, db.closed or 0
            return {
                close = function() db.closed = db.closed + 1 end,
                rowexec = function(_, sql)
                    if sql:find("count%(%*%)") then return ffi.new("int64_t", 3), ffi.new("int64_t", 9000), ffi.new("int64_t", 420) end
                    if sql:find("count%(DISTINCT date") then return ffi.new("int64_t", db.period_days or 2) end
                end,
                exec = function(_, sql)
                    if sql:find("GROUP BY d ORDER BY d") then
                        if db.days_error then error("days broke") end
                        return db.days
                    end
                    if sql:find("ORDER BY last_open") then return db.recent end
                    if sql:find("JOIN book") then
                        local s, e = sql:match("start_time >= (%d+) AND p.start_time < (%d+)")
                        db.period_calls = db.period_calls or {}
                        table.insert(db.period_calls, { tonumber(s), tonumber(e) })
                        return db.period and db.period(tonumber(s), tonumber(e))
                    end
                end,
            }
        end,
    },
}
for _, name in ipairs({
    "ui/widget/container/bottomcontainer", "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
    "ui/widget/imagewidget", "ui/widget/infomessage", "ui/widget/container/inputcontainer",
    "ui/widget/overlapgroup", "ui/widget/progresswidget", "ui/widget/textboxwidget",
    "ui/widget/textwidget", "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/widget/widget",
    "ui/widget/container/widgetcontainer",
}) do
    stubs[name] = class(name:match("([^/]+)$"):gsub("^%l", string.upper)
        :gsub("group$", "Group"):gsub("widget$", "Widget"):gsub("span$", "Span"))
end
stubs["ui/widget/infomessage"].kind = "InfoMessage"
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end

local Screen = stubs["device"].screen
local ReadHistory = stubs["readhistory"]

-- Column-major result like conn:exec, with int64 cdata numbers.
local function cols(rows)
    if #rows == 0 then return nil end
    local res = {}
    for c = 1, #rows[1] do
        res[c] = {}
        for r, row in ipairs(rows) do
            local v = row[c]
            res[c][r] = type(v) == "number" and ffi.new("int64_t", v) or v
        end
    end
    return res
end

local today = os.date("%Y-%m-%d")
local Data = require("blossom_data")

local function book(title, md5, secs, pages, read)
    -- title, authors, md5, pages, read_pages, seconds, period_pages
    return { title, "Author " .. title, md5, pages, read, secs, 10 }
end

local function resetDB()
    for k in pairs(db) do db[k] = nil end
    fs = { [settings_dir .. "/statistics.sqlite3"] = true, ["/books/a.epub"] = true, ["/books/b.epub"] = true }
    db.days = cols({ { Data.addDays(today, -1), 1200 }, { today, 600 } })
    db.recent = cols({
        { "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 300, 5400 },
        { "Atomic Habits", "James Clear", "zzz", 200, 50, 1800 },
    })
    db.period = function()
        return cols({ book("Anathema", "md5:/books/a.epub", 3000, 300, 300), book("Lost", "nope", 600, 100, 10) })
    end
    ReadHistory.hist = { { file = "/books/gone.epub" }, { file = "/books/a.epub" }, { file = "/books/b.epub" } }
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_, file)
            return { has_cover = true, cover_bb = { file = file, free = function(self) self.freed = true end } }
        end,
    }
    Screen.w, Screen.h = 600, 800
    shown, closed, dirty = {}, {}, {}
end

-- Helpers ------------------------------------------------------------------
local function walk(w, fn, seen)
    seen = seen or {}
    if type(w) ~= "table" or seen[w] then return end
    seen[w] = true
    fn(w)
    for _, c in ipairs(w) do walk(c, fn, seen) end
end

local function texts(w)
    local out = {}
    walk(w, function(n) if type(n.text) == "string" then out[#out + 1] = n.text end end)
    return table.concat(out, "\n")
end

local function count(w, kind)
    local n = 0
    walk(w, function(x) if x.kind == kind then n = n + 1 end end)
    return n
end

local Blossom = require("main")
local BlossomView = require("blossom_view")
local Covers = require("blossom_covers")

local registered
local function newPlugin(ui)
    ui = ui or {}
    ui.menu = { registerToMainMenu = function(_, p) registered = p end }
    return Blossom:new{ ui = ui }
end

local function openView(ui)
    local p = newPlugin(ui)
    p:show()
    local view = shown[#shown]
    assert(getmetatable(view) == BlossomView, "dashboard shown")
    return view, p
end

-- Tests --------------------------------------------------------------------

test("plugin registers menu and dispatcher action", function()
    resetDB()
    local p = newPlugin()
    eq(registered == p, true)
    eq(dispatched.id, "blossom_show")
    eq(dispatched.def.event, "BlossomShow")
    local items = {}
    p:addToMainMenu(items)
    eq(items.blossom.sorting_hint, "tools")
    assert(items.blossom.text:find("Blossom"))
    items.blossom.callback()
    eq(getmetatable(shown[#shown]) == BlossomView, true)
    eq(p:onBlossomShow(), true)
end)

test("overview shows totals from the DB (cdata converted) and closes the DB", function()
    resetDB()
    local view = openView()
    local s = view.stats
    eq({ s.books, s.seconds, s.pages, s.streak, s.today_seconds }, { 3, 9000, 420, 2, 600 })
    eq(s.recent[1].finished, true)
    local t = texts(view)
    assert(t:find("books loved"), t)
    assert(t:find("2h 30m"), t)
    assert(t:find("days streak"), t)
    assert(t:find("My reading garden"), t)
    eq(db.opened, db.closed)
end)

test("week page shows chart, flowers and books with covers or placeholders", function()
    resetDB()
    local view = openView()
    view:onNextPage()
    eq(view.page, 2)
    local t = texts(view)
    assert(t:find("Books that kept me company"), t)
    assert(t:find("my last 14 days"), t)
    assert(t:find("✿$") or t:find("✿ ·") or t:find("· ✿"), "flower row")
    eq(count(view, "ImageWidget"), 1)
    assert(t:find("✿\nLost"), "placeholder tile for unknown book")
    local bars = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.Bar then bars = bars + 1 end end)
    eq(bars, 7)
    local s, e = Data.weekBounds(today)
    eq(db.period_calls[1], { s, e })
    eq(dirty[#dirty], "flashui")
end)

test("period loads once with a loading message; revisits are cached", function()
    resetDB()
    local view = openView()
    view:goToPage(2)
    local infos = 0
    for _, w in ipairs(shown) do if w.kind == "InfoMessage" then infos = infos + 1 end end
    eq(infos, 1)
    eq(closed[#closed].kind, "InfoMessage")
    view:goToPage(1)
    view:goToPage(2)
    eq(#db.period_calls, 1)
end)

test("week with no books shows a sweet message", function()
    resetDB()
    db.period = function() return nil end
    local view = openView()
    view:goToPage(2)
    assert(texts(view):find("No books yet this week"))
end)

test("tiny screen falls back to a list instead of covers", function()
    resetDB()
    Screen.h = 330
    local view = openView()
    view:goToPage(2)
    eq(count(view, "ImageWidget"), 0)
    assert(texts(view):find("✿ Anathema · 50m"), texts(view))
end)

test("books page lists progress ribbons and finished hearts", function()
    resetDB()
    local view = openView()
    view:goToPage(3)
    local t = texts(view)
    assert(t:find("finished ♥"), t)
    assert(t:find("25%% · 30m"), t)
    eq(count(view, "ProgressWidget"), 2)
end)

test("month page: covers grid, navigation, no future months", function()
    resetDB()
    local view = openView()
    view:goToPage(4)
    local now = os.date("*t")
    local t = texts(view)
    assert(t:find(Data.monthTitle(now.year, now.month), 1, true), t)
    assert(t:find("1h 00m · 20 pages · 2 days · 2 books"), t)
    eq(count(view, "ImageWidget"), 1)

    view:shiftMonth(1)
    eq({ view.year, view.month }, { now.year, now.month })

    db.period = function() return nil end
    view:shiftMonth(-1)
    local py, pm = Data.shiftMonth(now.year, now.month, -1)
    eq({ view.year, view.month }, { py, pm })
    eq(db.period_calls[#db.period_calls], { Data.monthBounds(py, pm) })
    assert(texts(view):find("No blooms this month"))
end)

test("month with many books shows 9 tiles and +N more", function()
    resetDB()
    db.period = function()
        local list = {}
        for i = 1, 12 do list[i] = book("Book " .. i, "m" .. i, 100 * i, 100, 10) end
        return cols(list)
    end
    local view = openView()
    view:goToPage(4)
    local tiles = 0
    walk(view, function(n) if n.radius == 8 and n.padding == 4 then tiles = tiles + 1 end end)
    eq(tiles, 9)
    assert(texts(view):find("+3 more"))
end)

test("paging wraps both ways and swipes/keys navigate or close", function()
    resetDB()
    local view = openView()
    view:onPrevPage()
    eq(view.page, 4)
    view:onNextPage()
    eq(view.page, 1)
    view:onSwipe(nil, { direction = "west" })
    eq(view.page, 2)
    view:onSwipe(nil, { direction = "east" })
    eq(view.page, 1)
    eq(view.key_events.Close[1][1][1], "Back")
    view:onSwipe(nil, { direction = "south" })
    eq(closed[#closed] == view, true)
end)

test("closing frees covers and widgets", function()
    resetDB()
    local view = openView()
    view:goToPage(2)
    local bb = view.cover_bbs["md5:/books/a.epub"]
    local root = view[1]
    view:onClose()
    view:onCloseWidget()
    eq(bb.freed, true)
    eq(root.freed, true)
    eq(next(view.cover_bbs), nil)
end)

test("missing DB shows the empty garden", function()
    resetDB()
    fs[settings_dir .. "/statistics.sqlite3"] = nil
    local view = openView()
    eq(view.stats.empty, true)
    assert(texts(view):find("waiting to bloom"))
    view:goToPage(2)
    view:goToPage(3)
    assert(texts(view):find("No books on your shelf"))
    view:goToPage(4)
    assert(texts(view):find("No blooms this month"))
end)

test("DB that fails to open shows a gentle error", function()
    resetDB()
    db.open_error = "file is not a database"
    local view = openView()
    assert(texts(view):find("Couldn't open your reading statistics"))
end)

test("one failing query only empties its own section", function()
    resetDB()
    db.days_error = true
    local view = openView()
    eq(view.stats.books, 3)
    eq(view.stats.streak, 0)
    eq(#view.stats.recent, 2)
    eq(db.opened, db.closed)
end)

test("flushes in-memory statistics first; errors are tolerated", function()
    resetDB()
    local flushed = 0
    openView({ statistics = { insertDB = function() flushed = flushed + 1 end } })
    eq(flushed, 1)
    openView({ statistics = { insertDB = function() error("no doc") end } })
end)

test("covers: lazy history scan, cache, skips missing/broken files", function()
    local scanned = {}
    local c = Covers.new{
        history = function() return { { file = "/x" }, { file = "/gone" }, { file = "/bad" }, { file = "/y" } } end,
        fileExists = function(f) return f ~= "/gone" end,
        md5Of = function(f) table.insert(scanned, f); if f == "/bad" then error("boom") end return "sum" .. f end,
        coverOf = function(f) if f == "/y" then error("corrupt") end return { file = f } end,
    }
    eq(c:pathFor("sum/x"), "/x")
    eq(scanned, { "/x" })
    eq(c:pathFor("sum/x"), "/x")
    eq(#scanned, 1)
    eq(c:coverFor("sum/y"), nil) -- cover extraction error -> nil
    eq(scanned, { "/x", "/bad", "/y" })
    eq(c:pathFor("unknown"), nil)
    eq(c:pathFor(nil), nil)
    eq(c:coverFor("sum/x"), { file = "/x" })
end)

test("rows() converts column-major results", function()
    eq(Blossom.rows(nil, { "a" }), {})
    eq(Blossom.rows(cols({ { "t", 5 }, { "u", 7 } }), { "title", "n" }),
        { { title = "t", n = 5 }, { title = "u", n = 7 } })
end)

H.done()
