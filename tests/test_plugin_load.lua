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
        if self.kind == "Framecontainer" then
            -- Like KOReader: a frame is its content plus padding, border and margin (width/height ignored).
            local c = self[1] and self[1]:getSize() or { w = 0, h = 0 }
            local extra = 2 * ((self.padding or 5) + (self.bordersize or 0) + (self.margin or 0))
            return { w = c.w + extra, h = c.h + extra }
        end
        if self.dimen and self.dimen.h then return { w = self.dimen.w, h = self.dimen.h } end
        if self.width and self.height then return { w = self.width, h = self.height } end
        if self.text then return { w = #self.text * 8, h = 20 } end
        local w, h = 0, 0
        for _, c in ipairs(self) do
            local s = c.getSize and c:getSize() or { w = c.width or 0, h = 0 }
            if self.kind == "VerticalGroup" then
                self._cached_n = self._cached_n or #self
                w, h = math.max(w, s.w), h + s.h
            else
                w, h = w + s.w, math.max(h, s.h)
            end
        end
        return { w = w, h = h }
    end
    function C:resetLayout()
        self._cached_n = nil
    end
    function C:free()
        self.freed = true
        for _, c in ipairs(self) do if type(c) == "table" and c.free then c:free() end end
    end
    return C
end

-- Minimal blitbuffer: size, blitFrom log, free flag.
local function fakeBB(w, h, extra)
    local bb = extra or {}
    bb.w, bb.h, bb.blits = w, h, {}
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:getType() return 1 end
    function bb:blitFrom(src, dx, dy, ox, oy, bw, bh) table.insert(self.blits, { dx, dy, ox, oy, bw, bh }) end
    function bb:free() self.freed = true end
    return bb
end

local shown, closed, dirty = {}, {}, {}
local dispatched
local fs = {}          -- path -> true for files that "exist"
local db = {}          -- fake database behaviour
local settings_dir = "/kosettings"

local stubs = {
    ["ffi/blitbuffer"] = {
        COLOR_WHITE = 0xFF, COLOR_BLACK = 0, Color8 = function(v) return v end,
        new = function(w, h) return fakeBB(w, h) end,
    },
    ["ui/renderimage"] = {
        scaleBlitBuffer = function(_, bb, w, h)
            if bb:getWidth() == w and bb:getHeight() == h then return bb end
            local out = fakeBB(w, h); out.scaled_from = bb; return out
        end,
    },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["ui/size"] = { padding = { default = 5 }, border = { thin = 1, thick = 2 }, radius = { window = 8 }, line = { thin = 1, medium = 1 } },
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
            if db.sidecar_error then error(db.sidecar_error) end
            return { readSetting = function(_, key)
                if key == "partial_md5_checksum" then return db.sidecar_md5 and db.sidecar_md5[file] end
                return db.sidecar and db.sidecar[file] and db.sidecar[file][key]
            end }
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
                    if sql:find("WHERE b.id = ") then
                        return db.book and db.book(tonumber(sql:match("WHERE b.id = (%d+)")))
                    end
                    if sql:find("HAVING last") then return db.year_finished end
                    if sql:find("GROUP BY d, b.id") then return db.day_books end
                    if sql:find("strftime") then return db.year_months end
                    if sql:find("GROUP BY d ORDER BY d") then
                        if db.days_error then error("days broke") end
                        return db.days
                    end
                    local order = sql:match("WHERE total_read_time > 0 ORDER BY (.-);")
                    if order and not sql:find("LIMIT") then db.last_order = order; return db.all_books or db.recent end
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
    "ui/widget/container/widgetcontainer", "ui/widget/container/leftcontainer", "ui/widget/rectspan",
    "ui/widget/linewidget", "ui/widget/spinwidget",
}) do
    stubs[name] = class(name:match("([^/]+)$"):gsub("^%l", string.upper)
        :gsub("group$", "Group"):gsub("widget$", "Widget"):gsub("span$", "Span"))
end
stubs["ui/widget/infomessage"].kind = "InfoMessage"
stubs["ui/widget/spinwidget"].kind = "SpinWidget"

_G.G_reader_settings = {
    data = {},
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    flush = function(self) self.flushed = true end,
}
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

local next_id = 100
local function book(title, md5, secs, pages, read)
    -- id, title, authors, md5, pages, read_pages, seconds, period_pages
    next_id = next_id + 1
    return { next_id, title, "Author " .. title, md5, pages, read, secs, 10 }
end

local function resetDB()
    for k in pairs(db) do db[k] = nil end
    fs = { [settings_dir .. "/statistics.sqlite3"] = true, ["/books/a.epub"] = true, ["/books/b.epub"] = true }
    db.days = cols({ { Data.addDays(today, -1), 1200 }, { today, 600 } })
    db.recent = cols({
        { 1, "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 300, 5400 },
        { 2, "Atomic Habits", "James Clear", "zzz", 200, 50, 1800 },
    })
    db.book = function(id)
        if id ~= 2 then return nil end
        -- id, title, authors, md5, pages, read_pages, seconds, highlights, notes, first, last, days
        return cols({ { 2, "Atomic Habits", "James Clear", "zzz", 200, 50, 1800, 4, 1,
            os.time{ year = 2026, month = 8, day = 3, hour = 9 }, os.time{ year = 2026, month = 9, day = 29, hour = 9 }, 5 } })
    end
    db.year_finished = cols({ { 300, 300, os.time() }, { 200, 50, os.time() } })
    db.year_months = cols({ { os.date("%m"), 5400, 120 } })
    -- date, id, md5, seconds: today Anathema (a.epub) beats Atomic Habits; yesterday only an uncovered book.
    db.day_books = cols({
        { today, 2, "zzz", "Atomic Habits", 300 },
        { today, 1, "md5:/books/a.epub", "Anathema", 900 },
        { Data.addDays(today, -1) >= os.date("%Y-%m-01") and Data.addDays(today, -1) or today, 7, "nope", "Lost", 100 },
    })
    G_reader_settings.data = {}
    db.period = function()
        return cols({ book("Anathema", "md5:/books/a.epub", 3000, 300, 300), book("Lost", "nope", 600, 100, 10) })
    end
    ReadHistory.hist = { { file = "/books/gone.epub" }, { file = "/books/a.epub" }, { file = "/books/b.epub" } }
    package.loaded["bookinfomanager"] = {
        getBookInfo = function(_, file)
            return { has_cover = true, cover_bb = fakeBB(300, 450, { file = file }) }
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

-- Counts widgets of a kind; ImageWidgets count covers only (not the bow icon).
local function count(w, kind)
    local n = 0
    walk(w, function(x) if x.kind == kind and not x.file then n = n + 1 end end)
    return n
end

-- Reads a dots pager (‹ • 🌱 • ›) under `root`: returns "page/total", or nil when there is none.
local function pagerState(root)
    local found
    walk(root, function(n)
        if found or n.kind ~= "HorizontalGroup" then return end
        local first = n[1]
        if not (first and first.text == "‹" and first.width == 44) then return end
        local dots = n[3]
        local page, total = nil, 0
        for _, c in ipairs(dots) do
            if c.text == "●" then total = total + 1 end
            if c.file and c.file:find("sprout") then total = total + 1; page = total end
        end
        found = string.format("%d/%d", page or 0, total)
    end)
    return found
end

local function bows(w)
    local n = 0
    walk(w, function(x) if x.kind == "ImageWidget" and x.file and x.file:find("icons/bow.svg$") then n = n + 1 end end)
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

test("week page: frameless chart, summary below it, covers; no flower row", function()
    resetDB()
    local view = openView()
    view:onNextPage()
    eq(view.page, 2)
    local t = texts(view)
    assert(t:find("Books that kept me company"), t)
    assert(not t:find("my last 14 days"), t)
    assert(t:find(Data.weekdayLabel(today) .. "\n30m of reading ♡\nbest day: "), t) -- summary right after the chart
    walk(view, function(n) assert(not (n.kind == "Framecontainer" and n.bordersize == 1 and n.background == 0xFF and n.padding ~= 0 and n.radius == 8 and not n.overlap_offset and n[1] and n[1].kind == "Horizontalgroup"), "no chart frame") end)
    eq(count(view, "ImageWidget"), 1)
    assert(t:find("❀\nLost"), "placeholder tile for unknown book")
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
    assert(texts(view):find("❀ Anathema · 50m"), texts(view))
end)

test("books page is an edge-to-edge cover gallery with % and hours", function()
    resetDB()
    local view = openView()
    view:goToPage(3)
    local t = texts(view)
    assert(t:find("Anathema\n1h 30m"), t)
    assert(t:find("Atomic Habits\n25%% · 30m"), t)
    eq(count(view, "ProgressWidget"), 0)
    local tiles = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 2)
end)

test("books gallery shows at most 8 covers, 4 per row", function()
    resetDB()
    local list = {}
    for i = 1, 9 do list[i] = { i, "Book " .. i, "A", "m" .. i, 100, 10, 60 } end
    db.recent = cols(list)
    local view = openView()
    view:goToPage(3)
    local tiles = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 8)
    eq(pagerState(view), "1/2") -- 9 books: two pages
    local rows = 0
    walk(view, function(n)
        if n.kind == "HorizontalGroup" then
            local frames = 0
            for _, c in ipairs(n) do
                walk(c, function(x) if getmetatable(x) == BlossomView.RoundedFrame then frames = frames + 1 end end)
            end
            if frames == 4 then rows = rows + 1 end
        end
    end)
    eq(rows, 2)
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

test("month is a My-books-style gallery: 6 framed tiles per page, paged", function()
    resetDB()
    db.period = function()
        local list = {}
        for i = 1, 12 do list[i] = book("Book " .. i, "m" .. i, 100 * i, 100, 10) end
        return cols(list)
    end
    local view = openView()
    view:goToPage(4)
    local tiles = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 6)
    eq(pagerState(view), "1/2")
    -- most-read first, with title and "% · time" like My books
    assert(texts(view):find("Book 12\n10%% · 20m"), texts(view))
    local function pagerArrow(glyph)
        local found
        walk(view, function(n) if n.text == glyph and n.enabled ~= nil and n.width == 44 then found = n end end)
        return found
    end
    pagerArrow("›").callback()
    tiles = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 6)
    eq(pagerState(view), "2/2")
    assert(texts(view):find("Book 6\n"), texts(view))
    eq(pagerArrow("›").enabled, false)
    pagerArrow("‹").callback()
    eq(pagerState(view), "1/2")
end)

test("paging wraps both ways and swipes/keys navigate or close", function()
    resetDB()
    local view = openView()
    view:onPrevPage()
    eq(view.page, 5)
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

local function lastOfKind(kind)
    for i = #shown, 1, -1 do if shown[i].kind == kind then return shown[i] end end
end

local function findTappable(view, pred)
    local found
    walk(view, function(n)
        if not found and getmetatable(n) == BlossomView.Tappable and pred(texts(n)) then found = n end
    end)
    return found
end

test("My books rows show small covers or flower placeholders", function()
    resetDB()
    local view = openView()
    view:goToPage(3)
    eq(count(view, "ImageWidget"), 1)
    local tappables = 0
    walk(view, function(n) if getmetatable(n) == BlossomView.Tappable then tappables = tappables + 1 end end)
    eq(tappables, 3) -- two books + the close flower
end)

test("tapping a book opens its detail page", function()
    resetDB()
    local view = openView()
    view:goToPage(3)
    local row = findTappable(view, function(t) return t:find("Atomic Habits") end)
    assert(row, "row for Atomic Habits")
    eq(row:onTap(), true)
    local detail = shown[#shown]
    eq(getmetatable(detail) == require("blossom_detail"), true)
    local t = texts(detail)
    assert(t:find("Book details"), t)
    -- order: title, author, (snippet), wave, "25% read · 50 of 200 pages"
    assert(t:find("Atomic Habits\nJames Clear\n25%% read · 50 of 200 pages"), t)
    local wave
    walk(detail, function(n) if getmetatable(n) == BlossomView.GoalWave then wave = n end end)
    eq(wave.ratio, 0.25)
    assert(t:find("♡ 30m\ntime together"), t)
    assert(t:find("✧ 100\npages per hour"), t)
    assert(t:find("☾ 1h 30m\nleft to read"), t) -- 150 pages * 36 s
    assert(t:find("♥ 0\nhighlights\n☆ 0\nbookmarks"), t)
    assert(t:find("first read 3 Aug 2026 · last read 29 Sep 2026"), t)
    assert(t:find("No highlights yet"), t)
    -- no framed cards any more
    walk(detail, function(n) assert(not (n.kind == "Framecontainer" and n.background == 0xEE), "no card frames") end)
    detail:onSwipe(nil, { direction = "south" })
    eq(closed[#closed] == detail, true)
    detail:onCloseWidget()
    eq(view.cover_bbs["zzz"], false, "dashboard keeps owning covers")
end)

test("tapping a cover tile opens detail; unknown book shows a message", function()
    resetDB()
    local view = openView()
    view:goToPage(4)
    local tile = findTappable(view, function(t) return t:find("50m") end)
    tile:onTap() -- Anathema (id 101+) is not in db.book
    eq(lastOfKind("InfoMessage").text, "Couldn't find this book's petals ❀")
    view:openBook(nil)
    eq(lastOfKind("InfoMessage").timeout, 3)
end)

test("month calendar toggle: Sunday-first grid and back to covers", function()
    resetDB()
    local view = openView()
    view:goToPage(4)
    -- header: ▦ ‹ Month › ❀ as plain icons (no frames); active black, inactive gray
    local t0 = texts(view)
    assert(t0:find("▦\n‹\n" .. Data.monthTitle(tonumber(os.date("%Y")), tonumber(os.date("%m"))) .. "\n›\n"), t0)
    local function modeButtons()
        local btns, icons = {}, {}
        walk(view, function(n)
            if getmetatable(n) == BlossomView.Tappable then
                walk(n, function(c) if c.mode_key then btns[c.mode_key], icons[c.mode_key] = n, c end end)
            end
        end)
        return btns, icons
    end
    local btns, icons = modeButtons()
    eq({ icons.covers.active, icons.calendar.active, icons.calendar.fgcolor }, { true, false, 0x99 })
    assert(icons.covers.file:find("icons/rose_bloom%.svg$"), "covers button is the drawn rose (dark while active)")
    walk(btns.calendar, function(n) assert(n.kind ~= "Framecontainer", "icons have no frame") end)
    btns.calendar:onTap()
    eq(view.month_mode, "calendar")
    local _, icons2 = modeButtons()
    assert(icons2.covers.file:find("rose_bloom_soft"), "inactive rose is soft")
    local t = texts(view)
    assert(t:find("Su\nMo\nTu"), t)
    assert(t:find("less"), t)
    local now = os.date("*t")
    local days = 0
    walk(view, function(n) if n.bordersize and n.radius == 8 and n.width and n.width == n.height then days = days + 1 end end)
    eq(days, Data.daysInMonth(now.year, now.month))
    local today_cell
    walk(view, function(n) if n.color == 0 and n.radius == 8 then today_cell = n end end)
    assert(today_cell, "today is outlined in ink")
    -- previous month keeps calendar mode
    view:shiftMonth(-1)
    assert(texts(view):find("less"))
    btns = modeButtons()
    btns.covers:onTap()
    eq(view.month_mode, "covers")
end)

test("year page: goal hearts, status, month chart", function()
    resetDB()
    local view = openView()
    view:goToPage(5)
    local t = texts(view)
    assert(t:find("my " .. os.date("%Y") .. " reading goal\n1\n of 12 books"), t)
    assert(t:find("8%% of my goal · right on track ❀", 1, true) or t:find("8%% of my goal · %d"), t)
    eq(count(view, "ProgressWidget"), 0)
    assert(t:find("My year"), t)
    local gb
    walk(view, function(n) if getmetatable(n) == BlossomView.GoalWave then gb = n end end)
    assert(gb, "goal bar")
    eq(gb.ratio, 1 / 12)
    assert(not t:find("♥  ♡"), "no heart row")
    assert(t:find("1h 30m\nread\n120\npages\n2\ndays"), t)
    local pencil
    walk(view, function(n) if n.file and n.file:find("icons/pencil.svg$") then pencil = n end end)
    assert(pencil, "pencil icon beside the goal")
    local bars, chart = 0, nil
    walk(view, function(n)
        if getmetatable(n) == BlossomView.Bar then bars = bars + 1 end
        if getmetatable(n) == BlossomView.LineChart then chart = n end
    end)
    eq(bars, 0) -- a line chart now, not bars
    eq({ #chart.values, chart.upto, chart.best }, { 12, tonumber(os.date("%m")), tonumber(os.date("%m")) })
    assert(t:find("J\nF\nM\nA\nM\nJ\nJ\nA\nS\nO\nN\nD"), t)
    eq(view.periods["year:" .. os.date("%Y")].finished, 1)
    eq(view.periods["year:" .. os.date("%Y")].best_month, tonumber(os.date("%m")))
end)

test("setting the goal saves it and refreshes", function()
    resetDB()
    local view = openView()
    view:goToPage(5)
    local btn = findTappable(view, function() return false end)
    walk(view, function(n)
        if getmetatable(n) == BlossomView.Tappable then
            walk(n, function(c) if c.file and c.file:find("icons/pencil.svg$") then btn = n end end)
        end
    end)
    btn:onTap()
    local spin = lastOfKind("SpinWidget")
    eq({ spin.value, spin.value_min, spin.value_max }, { 12, 1, 365 })
    spin.callback({ value = 30 })
    eq(G_reader_settings.data.blossom.yearly_goal, 30)
    eq(G_reader_settings.flushed, true)
    local t = texts(view)
    assert(t:find("1\n of 30 books"), t)
    assert(t:find("3%% of my goal · "), t)
    eq(count(view, "ProgressWidget"), 0)
    local gb
    walk(view, function(n) if getmetatable(n) == BlossomView.GoalWave then gb = n end end)
    eq(gb.ratio, 1 / 30)
    -- reopen: goal persisted
    local again = openView()
    again:goToPage(5)
    assert(texts(again):find("1\n of 30 books"))
end)

test("invalid saved goal falls back to 12", function()
    resetDB()
    G_reader_settings.data.blossom = { yearly_goal = "lots" }
    local view = openView()
    view:goToPage(5)
    assert(texts(view):find("1\n of 12 books"))
end)

test("empty year shows a fresh-year message", function()
    resetDB()
    fs[settings_dir .. "/statistics.sqlite3"] = nil
    local view = openView()
    view:goToPage(5)
    assert(texts(view):find("0\n of 12 books"))
    assert(texts(view):find("0%% of my goal · a fresh year to bloom ❀"))
    assert(texts(view):find("a fresh year to bloom"))
end)

test("all pages have real color values and fresh layouts", function()
    resetDB()
    local view = openView()
    local function check(root, where)
        walk(root, function(n)
            for _, k in ipairs({ "background", "color", "fgcolor", "bgcolor", "bordercolor", "fillcolor" }) do
                if n[k] ~= nil then
                    assert(type(n[k]) == "number", string.format("%s: %s.%s is a %s", where, tostring(n.kind), k, type(n[k])))
                end
            end
        end)
    end
    for page = 1, #BlossomView.PAGES do
        view:goToPage(page)
        check(view, BlossomView.PAGES[page])
        walk(view, function(n)
            if n._cached_n then
                assert(n._cached_n == #n, BlossomView.PAGES[page] .. ": VerticalGroup grew after its layout was cached")
            end
        end)
    end
    view.month_mode = "calendar"
    view:goToPage(4)
    check(view, "calendar")
    view:openBook(2)
    check(shown[#shown], "detail")
end)

test("loadBook handles bad ids and missing rows", function()
    resetDB()
    local p = newPlugin()
    eq(p:loadBook(nil), nil)
    eq(p:loadBook(999), nil)
    eq(p:loadBook(2).title, "Atomic Habits")
end)

test("calendar days show only the date; bars carry each book's time", function()
    resetDB()
    local y = Data.addDays(today, -1)
    local d2 = Data.addDays(today, -2)
    db.day_books = cols({
        { d2, 1, "md5:/books/a.epub", "Anathema", 300 },
        { y, 1, "md5:/books/a.epub", "Anathema", 300 },
        { today, 1, "md5:/books/a.epub", "Anathema", 900 },
        { y, 2, "zzz", "Atomic Habits", 200 },
        { today, 2, "zzz", "Atomic Habits", 100 },
        { today, 7, "nope", "Lost", 50 }, -- one day only: no bar
    })
    local view = openView()
    view.month_mode = "calendar"
    view:goToPage(4)
    eq(count(view, "ImageWidget"), 0)
    local d = tostring(tonumber(os.date("%d")))
    local day_tile = findTappable(view, function(t) return t == d end)
    assert(day_tile, "today's cell is tappable")
    eq(texts(day_tile), d) -- just the date; time lives on the book bars
    local bars = {}
    walk(view, function(n)
        if n.kind == "Framecontainer" and n.color == 0 and n.overlap_offset then bars[#bars + 1] = n end
    end)
    local titles = {}
    for _, b in ipairs(bars) do titles[#titles + 1] = texts(b) end
    table.sort(titles)
    -- Anathema (3 days) and Atomic Habits (2 days); split in two if the days cross a week
    assert(#bars >= 2 and #bars <= 4, #bars)
    assert(titles[1]:find("^Anathema · ") and titles[#titles]:find("^Atomic Habits · "), table.concat(titles, ","))
    local all = table.concat(titles, ",")
    assert(all:find("Atomic Habits · 5m") or all:find("Atomic Habits · 3m"), all)
    assert(not texts(view):find("Lost"), "one-day read has no bar")
    -- lanes stack: Atomic Habits sits above Anathema on shared days
    local ys = {}
    for _, b in ipairs(bars) do ys[texts(b):match("^(.-) · ")] = b.overlap_offset[2] end
    assert(ys["Atomic Habits"] < ys["Anathema"], "second lane is higher")
    assert(texts(view):find("less"))
end)

test("calendar without day data falls back to plain days", function()
    resetDB()
    db.day_books = nil
    local view = openView()
    view.month_mode = "calendar"
    view:goToPage(4)
    eq(count(view, "ImageWidget"), 0)
end)

local function openToday(view)
    view.month_mode = "calendar"
    view:goToPage(4)
    local cell = findTappable(view, function(t) return t == tostring(tonumber(os.date("%d"))) end)
    assert(cell, "today's cell is tappable")
    cell:onTap()
    local page = shown[#shown]
    eq(getmetatable(page) == require("blossom_day"), true)
    return page
end

test("tapping a day shows its books, highlights and bookmarks", function()
    resetDB()
    db.sidecar = { ["/books/a.epub"] = { annotations = {
        { datetime = today .. " 21:00:00", drawer = "lighten", text = "She was the storm.", note = "chills ♡", pageno = 88, chapter = "Nine" },
        { datetime = today .. " 20:00:00", text = "in Nine", pageno = 80, chapter = "Nine" },
        { datetime = "2001-01-01 10:00:00", drawer = "lighten", text = "old one" },
    } } }
    local view = openView()
    local page = openToday(view)
    local t = texts(page)
    assert(t:find("^Blossom\n" .. tonumber(os.date("%d")) .. "\n" .. Data.daySubtitle(today)), t)
    assert(t:find("1h 00m\nread\n"), t)
    assert(t:find("1\nhighlight\n1\nbookmark"), t)
    assert(t:find("books I read"), t)
    assert(t:find("50m"), t) -- Anathema's time that day, under its cover
    assert(t:find("“She was the storm.”", 1, true), t)
    assert(t:find("Anathema · p. 88 · 21:00", 1, true), t)
    assert(t:find("✎ chills ♡", 1, true), t)
    assert(t:find("☆  p. 80 · Nine · Anathema · 20:00", 1, true), t)
    assert(not t:find("old one"), t)
    local s, e = Data.dayBounds(today)
    eq(db.period_calls[#db.period_calls], { s, e })
    -- book rows open the book's details
    local row = findTappable(page, function(x) return x:find("50m") end)
    assert(row, "book row tappable")
    page:onSwipe(nil, { direction = "south" })
    eq(closed[#closed] == page, true)
    page:onCloseWidget()
end)

test("day page: empty notes and many highlights", function()
    resetDB()
    local view = openView()
    local page = openToday(view)
    local t = texts(page)
    assert(t:find("No highlights or bookmarks"), t)

    resetDB()
    local many = {}
    for i = 1, 30 do
        many[i] = { datetime = string.format("%s 10:%02d:00", today, i), drawer = "lighten", text = "quote " .. i }
    end
    db.sidecar = { ["/books/a.epub"] = { annotations = many } }
    Screen.h = 900
    view = openView()
    page = openToday(view)
    t = texts(page)
    assert(t:find("quote 1”", 1, true), t)
    assert(not t:find("quote 30"), t)
    local state = pagerState(page)
    local total = tonumber(state:match("/(%d+)"))
    eq(state, "1/" .. total)
    for _ = 2, total do page:onSwipe(nil, { direction = "west" }) end
    assert(texts(page):find("quote 30”", 1, true), "the last page reaches the last highlight")
    assert(texts(page):find("^Blossom\n.-\nhighlights\n“"), "each page keeps its section title")
end)

test("day page: many books page four at a time", function()
    resetDB()
    db.period = function()
        local list = {}
        for i = 1, 6 do list[i] = book("D" .. i, "d" .. i, 100 * (7 - i), 100, 10) end
        return cols(list)
    end
    local page = openToday(openView())
    local state = pagerState(page)
    eq(state, "1/2")
    page.books_page = 2
    page:refresh()
    eq(pagerState(page), "2/2")
end)

test("day page survives unreadable sidecars and old bookmark format", function()
    resetDB()
    db.sidecar_error = "corrupt sidecar"
    local page = openToday(openView())
    assert(texts(page):find("No highlights or bookmarks"))
    resetDB()
    db.sidecar = { ["/books/a.epub"] = { bookmarks = {
        { datetime = today .. " 09:00:00", highlighted = true, notes = "legacy quote", page = 5 },
    } } }
    page = openToday(openView())
    assert(texts(page):find("“legacy quote”", 1, true))
end)

test("days without reading are not tappable", function()
    resetDB()
    local view = openView()
    view.month_mode = "calendar"
    view:shiftMonth(-3) -- a month with no reading at all
    view:goToPage(4)
    local n = 0
    walk(view, function(x)
        local tx = getmetatable(x) == BlossomView.Tappable and texts(x)
        if tx and tx ~= "▦" and tx ~= "" then n = n + 1 end -- not the mode icons or the close flower
    end)
    eq(n, 0)
end)

test("in the reader, book settings are saved first so today's notes are on disk", function()
    resetDB()
    local saved = 0
    openView({ document = {}, saveSettings = function() saved = saved + 1 end })
    eq(saved, 1)
end)

test("headers grow a row of flowers; bows only mark finished books", function()
    resetDB()
    local view = openView()
    eq(bows(view), 0)
    local header = view[1][1][1][1]
    local flowers = {}
    walk(header, function(n)
        local name = n.file and n.file:match("icons/(.-)%.svg$")
        if name and name ~= "close_flower" then flowers[#flowers + 1] = name end
    end)
    eq(flowers, { "lily", "lily", "sprout", "bud", "daisy", "tulip", "daisy", "bud", "sprout" }) -- title lilies, then the row
    assert(texts(header):find("^Blossom\n"), texts(header))
    assert(not texts(header):find("❀"), "drawn flowers, not symbols")
    assert(not texts(header):find("♡"), "no hearts in the header")
    view:goToPage(3)
    eq(bows(view), 1) -- finished Anathema
    view:goToPage(5)
    eq(bows(view), 0)
    view:openBook(2)
    eq(bows(shown[#shown]), 0) -- unfinished book
end)

test("pagination: soft dots, a sprout for the current page", function()
    resetDB()
    local view = openView()
    local function footerDots()
        local found
        walk(view, function(n)
            if n.kind == "HorizontalGroup" and not found then
                local dots, sprout = 0, 0
                for _, c in ipairs(n) do
                    if c.text == "●" then dots = dots + 1 end
                    if c.file and c.file:find("sprout") then sprout = sprout + 1 end
                end
                if dots + sprout == 5 then found = n end
            end
        end)
        return found
    end
    local row = footerDots()
    assert(row, "5 page markers")
    local first = row[1]
    assert(first.file and first.file:find("sprout"), "page 1 is the sprout")
    assert(not texts(view):find("♥ ♡"), "no hearts")
    view:goToPage(3)
    row = footerDots()
    local markers = {}
    for _, c in ipairs(row) do if c.text or c.file then markers[#markers + 1] = c.file and "sprout" or "dot" end end
    eq(markers, { "dot", "dot", "sprout", "dot", "dot" })
end)

test("the close button is a flower at the top-left", function()
    resetDB()
    local view = openView()
    local close
    walk(view, function(n)
        if getmetatable(n) == BlossomView.Tappable and n[1] and n[1].file and n[1].file:find("close_flower") then close = n end
    end)
    assert(close, "flower close button")
    eq(close.overlap_offset[1] < 60, true)
    eq(close.overlap_offset[2], 36) -- lower, level with the title
    close:onTap()
    eq(closed[#closed] == view, true)
end)

test("gallery covers are cropped to fill their box", function()
    resetDB()
    local view = openView()
    view:goToPage(3)
    local img
    walk(view, function(n) if n.kind == "ImageWidget" and n.image and n.image.blits then img = n end end)
    assert(img, "filled cover image")
    eq({ img.image.w, img.image.h, img.width, img.height, img.image_disposable }, { img.width, img.height, img.width, img.height, true })
    local blit = img.image.blits[1]
    -- 300x450 source scaled to cover: centred offset, full box copied
    eq({ blit[1], blit[2], blit[5], blit[6] }, { 0, 0, img.width, img.height })
    assert(blit[3] >= 0 and blit[4] >= 0)
    local src = view.cover_bbs["md5:/books/a.epub"]
    eq(src.freed, nil, "cached original is kept")
end)

test("goal wave clamps its fill and keeps the heart on the line", function()
    resetDB()
    local view = openView()
    local full = view:goalWave(1.7, 400)
    eq(full[1].ratio, 1)
    eq(full[2].overlap_offset[1], 400 - 16)
    local empty = view:goalWave(0, 400)
    eq(empty[1].ratio, 0)
    eq(empty[2].overlap_offset[1], 0)
    local half = view:goalWave(0.5, 400)
    eq(half[2].overlap_offset[1], 200 - 8)
    eq(full[2].width, 16) -- a small heart
    -- the heart sits on the wave: its centre is at the wave's height there
    local w = half[1]
    local hy = half[2].overlap_offset[2] + math.floor(16 * 44 / 48 / 2)
    assert(math.abs(hy - w:waveY(200)) <= 2, "heart rides the wave (within rounding)")
    assert(half[2].overlap_offset[2] >= 0 and half[2].overlap_offset[2] + 14 <= w.height, "heart inside the widget")
end)

test("rounded frame paints content, trims corners, then the border", function()
    local calls = {}
    local bb = setmetatable({}, { __index = function(_, k)
        return function(_, ...) table.insert(calls, { k, ... }) end
    end })
    local content = { getSize = function() return { w = 98, h = 148 } end,
                      paintTo = function(_, _, x, y) table.insert(calls, { "content", x, y }) end }
    local frame = BlossomView.RoundedFrame:new{ radius = 10, bordersize = 1, color = 0x77, background = 0xFF, outside = 0xFF, content }
    eq(frame:getSize(), { w = 100, h = 150 })
    frame:paintTo(bb, 5, 7)
    eq(calls[1][1], "paintRoundedRect")
    eq({ calls[2][1], calls[2][2], calls[2][3] }, { "content", 6, 8 })
    eq(calls[#calls][1], "paintBorder")
    local trims = 0
    for i = 3, #calls - 1 do
        eq(calls[i][1], "paintRect")
        trims = trims + 1
    end
    assert(trims > 0 and trims % 4 == 0, "four corners trimmed row by row")
    -- top-left first row cut is the widest, and stays inside the radius
    assert(calls[3][4] >= 1 and calls[3][4] <= 10)
end)

test("detail cover fills a rounded frame", function()
    resetDB()
    db.book = function()
        return cols({ { 1, "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 300, 5400, 2, 0, os.time() - 86400, os.time(), 3 } })
    end
    local view = openView()
    view:openBook(1)
    local detail = shown[#shown]
    local frame
    walk(detail, function(n) if getmetatable(n) == BlossomView.RoundedFrame then frame = n end end)
    assert(frame, "rounded cover frame")
    local img
    walk(frame, function(n) if n.kind == "ImageWidget" and n.image then img = n end end)
    assert(img and img.image.blits and #img.image.blits == 1, "cover cropped to fill")
    -- frame shaped like the 300x450 cover: nothing cropped
    eq(img.height, math.floor(img.width * 1.5))
    local blit = img.image.blits[1]
    assert(blit[3] <= 1 and blit[4] <= 1, "no trimming for a matching frame")
end)

test("year cards use gentler corners", function()
    resetDB()
    local view = openView()
    view:goToPage(5)
    local radii = {}
    walk(view, function(n) if n.kind == "Framecontainer" and n.bordersize == 0 and n.radius then radii[#radii + 1] = n.radius end end)
    eq(radii, { 10, 10 })
end)

test("garden is frameless and centred vertically", function()
    resetDB()
    local view = openView()
    local content = view[1][1][1][3] -- frame > overlap > column > content (after header, span)
    eq(content.kind, "VerticalGroup")
    -- the garden centred above, the flower bed at the very bottom of the page area
    local centre, bed = content[1], content[2]
    eq(centre.kind, "Centercontainer")
    eq(centre.dimen.h + bed.height, view.content_h)
    assert(bed.file:find("garden_bed"))
    local frames = 0
    walk(content, function(n) if n.kind == "Framecontainer" then frames = frames + 1 end end)
    eq(frames, 0)
    local t = texts(content)
    assert(not t:find("my garden in numbers"), t)
    assert(t:find("\n" .. Data.affirmation(today) .. "\n3\nbooks loved\n", 1, true), t) -- affirmation right under the greeting
    local aff
    walk(content, function(n) if n.text == Data.affirmation(today) then aff = n end end)
    eq({ aff.fgcolor, aff.face.size, aff.face.name }, { 0x55, 16, "NotoSerif-Italic.ttf" }) -- small, slanted, gray
    assert(t:find("3\nbooks loved\n2h 30m\nhours of stories\n420\npages turned\n2\ndays streak"), t)
    local icons = {}
    walk(content, function(n) if n.file then icons[#icons + 1] = n.file:match("icons/(.-)%.svg$") end end)
    for _, name in ipairs({ "tulip", "daisy", "sprout", "rose", "bud", "sunflower", "butterfly", "ladybug", "garden_bed" }) do
        local found = false
        for _, have in ipairs(icons) do if have == name then found = true end end
        assert(found, "garden grows a " .. name)
    end
    local bed
    walk(content, function(n) if n.file and n.file:find("garden_bed") then bed = n end end)
    eq({ bed.width, bed.height }, { view.inner_w, math.floor(view.inner_w * 90 / 600) }) -- full width, drawn proportions
    assert(t:find("longest streak: 2 days ☆"), t)
end)

test("book details show snippet, highlights and bookmark count from the sidecar", function()
    resetDB()
    db.book = function()
        return cols({ { 1, "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 300, 5400, 2, 0, os.time() - 86400, os.time(), 3 } })
    end
    db.sidecar = { ["/books/a.epub"] = {
        doc_props = { description = "<p>A <i>witchy</i> romance in the woods.</p>" },
        annotations = {
            { datetime = "2026-08-03 21:00:00", drawer = "lighten", text = "She was the storm.", note = "chills", pageno = 88, chapter = "Nine" },
            { datetime = "2026-08-04 21:00:00", drawer = "lighten", text = "Second quote.", pageno = 90 },
            { datetime = "2026-08-04 22:00:00", text = "in Ten", pageno = 99 },
        },
    } }
    local view = openView()
    view:openBook(1)
    local t = texts(shown[#shown])
    assert(t:find("Anathema\nKeri Lake\nA witchy romance in the woods.\nfinished · 300 of 300 pages"), t)
    assert(t:find("♥ 2\nhighlights\n☆ 1\nbookmark"), t)
    assert(t:find("“She was the storm.”", 1, true), t)
    assert(t:find("p. 88 · Nine · 3 Aug 2026", 1, true), t)
    assert(t:find("✎ chills", 1, true), t)
    assert(t:find("“Second quote.”", 1, true), t)
    eq(bows(shown[#shown]), 1) -- finished
end)

test("book details: many highlights are paged with dots", function()
    resetDB()
    db.book = function()
        return cols({ { 1, "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 100, 5400, 2, 0, os.time() - 86400, os.time(), 3 } })
    end
    local many = {}
    for i = 1, 25 do many[i] = { datetime = string.format("2026-08-%02d 10:00:00", i), drawer = "lighten", text = "quote " .. i } end
    db.sidecar = { ["/books/a.epub"] = { annotations = many } }
    local view = openView()
    view:openBook(1)
    local detail = shown[#shown]
    local t = texts(detail)
    assert(t:find("quote 1”", 1, true), t)
    assert(not t:find("quote 25"), t)
    local state = pagerState(detail)
    local total = tonumber(state:match("/(%d+)"))
    eq(state, "1/" .. total)
    assert(total >= 2)
    detail:onSwipe(nil, { direction = "west" })
    eq(pagerState(detail), "2/" .. total)
    assert(not texts(detail):find("quote 1”", 1, true))
    for _ = 1, total do detail:turnHighlights(1) end
    eq(pagerState(detail), total .. "/" .. total)
    assert(texts(detail):find("quote 25”", 1, true), "the last page reaches the last highlight")
    detail:onSwipe(nil, { direction = "east" })
    eq(pagerState(detail), (total - 1) .. "/" .. total)
end)

test("calendar day cells keep their full size", function()
    resetDB()
    local view = openView()
    view.month_mode = "calendar"
    view:goToPage(4)
    local sizes = {}
    walk(view, function(n)
        if n.kind == "Framecontainer" and n.radius == 8 and n.width and n.width == n.height then
            local s = n:getSize()
            sizes[#sizes + 1] = s.w == n.width and s.h == n.height
        end
    end)
    assert(#sizes >= 28)
    for _, ok in ipairs(sizes) do assert(ok, "a day cell shrank to its content") end
end)

test("book details always show at least one highlight", function()
    resetDB()
    Screen.h = 440
    db.book = function()
        return cols({ { 1, "Anathema", "Keri Lake", "md5:/books/a.epub", 300, 100, 5400, 2, 0, os.time() - 86400, os.time(), 3 } })
    end
    db.sidecar = { ["/books/a.epub"] = { doc_props = { description = string.rep("words ", 60) }, annotations = {
        { datetime = "2026-08-01 10:00:00", drawer = "lighten", text = string.rep("long ", 80), note = "note" },
        { datetime = "2026-08-02 10:00:00", drawer = "lighten", text = "second" },
    } } }
    local view = openView()
    view:openBook(1)
    local t = texts(shown[#shown])
    assert(t:find("“long", 1, true), t)
    assert(not t:find("✎ note", 1, true), "the shortened first highlight drops its note")
    eq(pagerState(shown[#shown]), "1/2")
end)

test("every page uses the same side margins", function()
    resetDB()
    local view = openView()
    local expected = Screen.w - 2 * 34
    eq(view.inner_w, expected)
    view:openBook(2)
    eq(shown[#shown].inner_w, expected)
    view.month_mode = "calendar"
    view:goToPage(4)
    local cell = findTappable(view, function(t) return t == tostring(tonumber(os.date("%d"))) end)
    cell:onTap()
    eq(shown[#shown].inner_w, expected)
end)

local function gardenTap(view, label)
    local found
    walk(view, function(n)
        if not found and getmetatable(n) == BlossomView.Tappable and texts(n):find("\n" .. label .. "$") then found = n end
    end)
    assert(found, "garden stat " .. label)
    found:onTap()
    return shown[#shown]
end

test("garden shows highlights and bookmarks counts; every number is tappable", function()
    resetDB()
    db.sidecar = {
        ["/books/a.epub"] = { doc_props = { title = "Anathema" }, annotations = {
            { datetime = "2026-08-03 21:00:00", drawer = "lighten", text = "She was the storm.", pageno = 88 },
            { datetime = "2026-09-01 21:00:00", text = "in Ten", pageno = 99, chapter = "Ten" },
        } },
        ["/books/b.epub"] = { annotations = {
            { datetime = "2026-09-20 10:00:00", drawer = "lighten", text = "Tiny habits.", pageno = 3 },
        } },
    }
    local view = openView()
    local t = texts(view)
    assert(t:find("2\nhighlights\n1\nbookmark"), t)
    local n = 0
    walk(view, function(x) if getmetatable(x) == BlossomView.Tappable then n = n + 1 end end)
    eq(n, 9) -- eight numbers + the close flower
end)

test("garden book pages are galleries: books, time, pages", function()
    resetDB()
    local list = {}
    for i = 1, 10 do list[i] = { i, "Book " .. i, "A", "m" .. i, 100, 10 * i, 60 * i } end
    db.all_books = cols(list)
    local view = openView()
    local more = gardenTap(view, "books loved")
    eq(getmetatable(more) == require("blossom_more"), true)
    local t = texts(more)
    assert(t:find("Books loved"), t)
    local tiles = 0
    walk(more, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 8) -- first page of 10
    eq(pagerState(more), "1/2")
    eq(db.last_order, "last_open DESC")
    more:onNextPage()
    tiles = 0
    walk(more, function(n) if getmetatable(n) == BlossomView.RoundedFrame then tiles = tiles + 1 end end)
    eq(tiles, 2)
    eq(pagerState(more), "2/2")
    more:onNextPage() -- no page 3
    eq(more.page, 2)

    local time = gardenTap(view, "hours of stories")
    eq(db.last_order, "total_read_time DESC")
    assert(texts(time):find("Hours of stories"))
    local pages = gardenTap(view, "pages turned")
    eq(db.last_order, "total_read_pages DESC")
    assert(texts(pages):find("Book 1\n10 pages"), texts(pages))
end)

test("garden period pages: streak, today, week", function()
    resetDB()
    local view = openView()
    local streak = gardenTap(view, "days streak")
    local from, to = Data.streakRange(view.stats.by_date, today, view.stats.streak)
    eq(db.period_calls[#db.period_calls], { Data.dayBounds(from), select(2, Data.dayBounds(to)) })
    assert(texts(streak):find("My streak"))
    gardenTap(view, "read today")
    eq(db.period_calls[#db.period_calls], { Data.dayBounds(today) })
    local week = gardenTap(view, "this week")
    assert(texts(week):find("This week"))
end)

test("highlights and bookmarks pages are lists with the book they're from, paged", function()
    resetDB()
    local many = {}
    for i = 1, 30 do
        many[#many + 1] = { datetime = string.format("2026-09-%02d 10:00:00", i), text = "bm", pageno = i, chapter = "Ch " .. i }
    end
    many[#many + 1] = { datetime = "2026-09-15 11:00:00", drawer = "lighten", text = "A quote.", pageno = 5, note = "aww" }
    db.sidecar = { ["/books/a.epub"] = { doc_props = { title = "Anathema" }, annotations = many } }
    local view = openView()
    local hl = gardenTap(view, "highlight")
    local t = texts(hl)
    assert(t:find("My highlights"), t)
    eq(pagerState(hl), nil) -- a single page needs no pager
    assert(t:find("“A quote.”", 1, true), t)
    assert(t:find("Anathema · p. 5 · 15 Sep 2026", 1, true), t)
    assert(t:find("✎ aww", 1, true), t)

    local bm = gardenTap(view, "bookmarks")
    t = texts(bm)
    assert(t:find("My bookmarks"), t)
    assert(t:find("☆  p. 30 · Ch 30", 1, true), t) -- newest first
    assert(t:find("Anathema · 30 Sep 2026", 1, true), t)
    assert(bm:hasNext(), "30 bookmarks need more than one page")
    bm:onNextPage()
    eq(bm.page, 2)
    assert(not texts(bm):find("p. 30 ·", 1, true))
    bm:onPrevPage()
    assert(texts(bm):find("p. 30 · Ch 30", 1, true))
    bm:onSwipe(nil, { direction = "south" })
    eq(closed[#closed] == bm, true)
    bm:onCloseWidget()
end)

test("empty garden pages say something sweet", function()
    resetDB()
    fs[settings_dir .. "/statistics.sqlite3"] = nil
    ReadHistory.hist = {}
    local view = openView()
    -- the empty garden has no numbers, so open the pages directly
    view:openMore("highlights")
    assert(texts(shown[#shown]):find("No highlights yet"))
    view:openMore("streak")
    assert(texts(shown[#shown]):find("No streak right now"))
end)

test("line chart points scale to the busiest month and stop at this month", function()
    local chart = BlossomView.LineChart:new{ width = 120, height = 100, values = { 0, 50, 100, 25 }, upto = 3, best = 3 }
    local x1, y1 = chart:point(1)
    local x3, y3 = chart:point(3)
    eq({ x1, y1 }, { 15, 92 }) -- zero sits on the bottom padding
    eq({ x3, y3 }, { 75, 8 })  -- the max touches the top padding
    chart.top_pad = 26
    eq(select(2, chart:point(3)), 26) -- room above the best point for the heart
    local calls = {}
    local bb = setmetatable({}, { __index = function(_, k) return function(_, ...) calls[#calls + 1] = { k, ... } end end })
    chart:paintTo(bb, 0, 0)
    local borders = 0
    for _, c in ipairs(calls) do if c[1] == "paintBorder" then borders = borders + 1 end end
    eq(borders, 3) -- dots only up to this month
    local flat = BlossomView.LineChart:new{ width = 120, height = 100, values = { 0, 0, 0, 0 } }
    eq(select(2, flat:point(2)), 92)
end)

test("pages opened from the dashboard have a back flower at the top-left", function()
    resetDB()
    local view = openView()
    local function backButton(page)
        local found
        walk(page, function(n)
            if getmetatable(n) == BlossomView.Tappable and n[1] and n[1].file and n[1].file:find("back_flower") then found = n end
        end)
        return found
    end
    assert(not backButton(view), "the dashboard itself closes, not goes back")
    view:openMore("highlights")
    local more = shown[#shown]
    local back = backButton(more)
    assert(back, "gallery/list pages have a back flower")
    eq(back.overlap_offset[1] < 60, true)
    back:onTap()
    eq(closed[#closed] == more, true)
    view:openBook(2)
    assert(backButton(shown[#shown]), "book details too")
end)

test("book details: reading days wears a drawn stemless rose", function()
    resetDB()
    local view = openView()
    view:openBook(2)
    local rose
    walk(shown[#shown], function(n)
        if n.kind == "HorizontalGroup" and n[1] and n[1].file and n[1].file:find("icons/rose_bloom%.svg$") then rose = n end
    end)
    assert(rose, "rose beside the reading-days number")
    eq(texts(rose), "5")
end)

test("bookmarks page lists bookmarks and highlights together, newest first", function()
    resetDB()
    db.sidecar = { ["/books/a.epub"] = { doc_props = { title = "Anathema" }, annotations = {
        { datetime = "2026-09-01 10:00:00", text = "in One", pageno = 4, chapter = "One" },
        { datetime = "2026-09-03 10:00:00", drawer = "lighten", text = "Newest quote.", pageno = 9 },
        { datetime = "2026-09-02 10:00:00", text = "in Two", pageno = 7, chapter = "Two" },
    } } }
    local view = openView()
    view:openMore("bookmarks")
    local t = texts(shown[#shown])
    assert(t:find("2 bookmarks · 1 highlight, newest first", 1, true), t)
    local q = t:find("“Newest quote.”", 1, true)
    local b2 = t:find("p. 7 · Two", 1, true)
    local b1 = t:find("p. 4 · One", 1, true)
    assert(q and b2 and b1 and q < b2 and b2 < b1, t)
    assert(t:find("Anathema · p. 9 · 3 Sep 2026", 1, true), t)
end)

test("week covers page 4 at a time", function()
    resetDB()
    db.period = function()
        local list = {}
        for i = 1, 6 do list[i] = book("W" .. i, "a" .. i, 100 * (7 - i), 100, 10) end
        return cols(list)
    end
    local view = openView()
    view:goToPage(2)
    local t = texts(view)
    eq(pagerState(view), "1/2")
    assert(not t:find("more"), "no +N more any more")
    view.sub_page.week = 2
    view:refresh()
    eq(pagerState(view), "2/2")
end)

test("highlight text keeps its own quotes out of ours", function()
    resetDB()
    db.sidecar = { ["/books/a.epub"] = { doc_props = { title = "Anathema" }, annotations = {
        { datetime = "2026-09-03 10:00:00", drawer = "lighten", text = '"Already quoted."', pageno = 9 },
        { datetime = "2026-09-04 10:00:00", drawer = "lighten", text = "“Curly too”", pageno = 10 },
    } } }
    local view = openView()
    view:openMore("highlights")
    local t = texts(shown[#shown])
    assert(t:find('“Already quoted.”', 1, true), t)
    assert(t:find('“Curly too”', 1, true), t)
    assert(not t:find('“"', 1, true) and not t:find("““", 1, true), "no doubled marks")
    local q
    walk(shown[#shown], function(n) if n.text == "“Curly too”" then q = n end end)
    eq(q.face.size, 15) -- smaller type on the highlights page
end)

test("long lists show a window of dots and a page count", function()
    resetDB()
    local many = {}
    for i = 1, 200 do
        many[i] = { datetime = string.format("2026-09-%02d %02d:%02d:00", 1 + i % 28, i % 24, i % 60), text = "bm", pageno = i }
    end
    db.sidecar = { ["/books/a.epub"] = { doc_props = { title = "Anathema" }, annotations = many } }
    local view = openView()
    view:openMore("bookmarks")
    local page = shown[#shown]
    local total = page:pageCount()
    assert(total > 9, total)
    eq(pagerState(page), "1/7") -- seven dots shown, sprout on the first
    assert(texts(page):find("1 / " .. total, 1, true))
    for _ = 1, 5 do page:onNextPage() end
    eq(pagerState(page), "4/7") -- the window follows, sprout in the middle
    assert(texts(page):find("6 / " .. total, 1, true))
end)

H.done()
