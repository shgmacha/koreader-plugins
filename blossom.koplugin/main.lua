--[[--
Blossom ❀ a cute reading diary for KOReader.

Reads the built-in Statistics plugin's database (read-only) and shows an
overview, a weekly bloom chart, recent-book progress and a monthly shelf of
covers in a soft, grayscale-friendly style.
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local logger = require("logger")
local _ = require("gettext")

local BlossomView = require("blossom_view")
local Covers = require("blossom_covers")
local Data = require("blossom_data")
local Theme = require("blossom_theme")

local RECENT_BOOKS = 8

local SQL_TOTALS = [[
    SELECT count(*), sum(total_read_time), sum(total_read_pages)
    FROM book WHERE total_read_time > 0;]]

local SQL_DAYS = [[
    SELECT date(start_time, 'unixepoch', 'localtime') AS d, sum(duration)
    FROM page_stat_data GROUP BY d ORDER BY d;]]

local SQL_RECENT = [[
    SELECT id, title, authors, md5, pages, total_read_pages, total_read_time
    FROM book WHERE total_read_time > 0
    ORDER BY last_open DESC LIMIT %d;]]

local SQL_PERIOD_BOOKS = [[
    SELECT b.id, b.title, b.authors, b.md5, b.pages, b.total_read_pages,
           sum(p.duration), count(DISTINCT p.page)
    FROM page_stat_data p JOIN book b ON b.id = p.id_book
    WHERE p.start_time >= %d AND p.start_time < %d
    GROUP BY b.id ORDER BY sum(p.duration) DESC;]]

local SQL_PERIOD_DAYS = [[
    SELECT count(DISTINCT date(start_time, 'unixepoch', 'localtime'))
    FROM page_stat_data WHERE start_time >= %d AND start_time < %d;]]

local SQL_BOOK = [[
    SELECT b.id, b.title, b.authors, b.md5, b.pages, b.total_read_pages, b.total_read_time,
           b.highlights, b.notes, min(p.start_time), max(p.start_time),
           count(DISTINCT date(p.start_time, 'unixepoch', 'localtime'))
    FROM book b LEFT JOIN page_stat_data p ON p.id_book = b.id
    WHERE b.id = %d GROUP BY b.id;]]

-- Books whose last reading session falls in the year; "finished" is decided in Lua.
local SQL_YEAR_FINISHED = [[
    SELECT b.pages, b.total_read_pages, max(p.start_time) AS last
    FROM book b JOIN page_stat_data p ON p.id_book = b.id
    GROUP BY b.id HAVING last >= %d AND last < %d;]]

local SQL_YEAR_MONTHS = [[
    SELECT strftime('%%m', start_time, 'unixepoch', 'localtime') AS m,
           sum(duration), count(DISTINCT id_book || '-' || page)
    FROM page_stat_data WHERE start_time >= %d AND start_time < %d GROUP BY m;]]

-- Time per book per day; the view keeps each day's longest.
local SQL_DAY_BOOKS = [[
    SELECT date(p.start_time, 'unixepoch', 'localtime') AS d, b.id, b.md5, b.title, sum(p.duration)
    FROM page_stat_data p JOIN book b ON b.id = p.id_book
    WHERE p.start_time >= %d AND p.start_time < %d
    GROUP BY d, b.id;]]

-- Every book with reading time, for the garden's gallery pages.
local SQL_ALL_BOOKS = [[
    SELECT id, title, authors, md5, pages, total_read_pages, total_read_time
    FROM book WHERE total_read_time > 0 ORDER BY %s;]]
local BOOK_ORDERS = {
    recent = "last_open DESC",
    time = "total_read_time DESC",
    pages = "total_read_pages DESC",
}

local SETTINGS_KEY = "blossom"

-- The pages Blossom can open on (the dashboard's five, plus the book being read).
local START_PAGES = {
    { key = "overview", text = _("My reading garden") },
    { key = "week", text = _("This week") },
    { key = "books", text = _("My books") },
    { key = "month", text = _("This month") },
    { key = "year", text = _("My year") },
    { key = "current_book", text = _("The book I'm reading") },
}

local Blossom = WidgetContainer:extend{
    name = "blossom",
    is_doc_only = false,
}

function Blossom:init()
    self.db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Blossom:onDispatcherRegisterActions()
    Dispatcher:registerAction("blossom_show", {
        category = "none",
        event = "BlossomShow",
        title = _("Blossom reading diary"),
        general = true,
    })
    Dispatcher:registerAction("blossom_show_book", {
        category = "none",
        event = "BlossomShowBook",
        title = _("This book in Blossom"),
        reader = true,
    })
end

function Blossom:addToMainMenu(menu_items)
    local start_pages = {}
    for _i, page in ipairs(START_PAGES) do
        start_pages[#start_pages + 1] = {
            text = page.text,
            radio = true,
            checked_func = function() return self:getSetting("start_page") == page.key end,
            callback = function() self:setSetting("start_page", page.key) end,
        }
    end
    menu_items.blossom = {
        text = _("❀ Blossom reading diary"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Blossom"),
                callback = function() self:show() end,
            },
            {
                text = _("This book in Blossom"),
                enabled_func = function() return self:isReading() end,
                callback = function() self:show({ book = true }) end,
                separator = true,
            },
            {
                text = _("Open as"),
                sub_item_table = {
                    {
                        text = _("Full screen"),
                        radio = true,
                        checked_func = function() return self:getSetting("open_as") ~= "window" end,
                        callback = function() self:setSetting("open_as", "fullscreen") end,
                    },
                    {
                        text = _("Floating window over my bookshelf or book"),
                        radio = true,
                        checked_func = function() return self:getSetting("open_as") == "window" end,
                        callback = function() self:setSetting("open_as", "window") end,
                    },
                },
            },
            {
                text_func = function()
                    local key = self:getSetting("start_page") or "overview"
                    for _i, page in ipairs(START_PAGES) do
                        if page.key == key then return T(_("Start on: %1"), page.text) end
                    end
                    return _("Start on")
                end,
                sub_item_table = start_pages,
            },
            {
                text_func = function() return T(_("Yearly goal: %1 books"), self:getGoal()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editGoalFromMenu(touchmenu_instance)
                end,
            },
        },
    }
end

function Blossom:onBlossomShowBook()
    self:show({ book = true })
    return true
end

function Blossom:isReading()
    return self.ui ~= nil and self.ui.document ~= nil
end

--- The statistics id of the open book (nil outside the reader or when unknown).
function Blossom:currentBookId()
    if not self:isReading() then return end
    local stats = self.ui.statistics
    if stats and tonumber(stats.id_curr_book) then return tonumber(stats.id_curr_book) end
    local md5 = self.ui.doc_settings and self.ui.doc_settings:readSetting("partial_md5_checksum")
    if type(md5) ~= "string" or not md5:match("^%x+$") then return end
    return self:withDB(function(conn)
        return tonumber(conn:rowexec(string.format("SELECT id FROM book WHERE md5 = '%s';", md5)))
    end)
end

function Blossom:editGoalFromMenu(touchmenu_instance)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Books to read this year ♡"),
        value = self:getGoal(),
        value_min = 1,
        value_max = 365,
        value_step = 1,
        value_hold_step = 5,
        ok_text = _("Save ♥"),
        callback = function(spin)
            self:setGoal(spin.value)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function Blossom:onBlossomShow()
    self:show()
    return true
end

-- Database -------------------------------------------------------------------

--- Saves page stats the Statistics plugin still holds in memory, so today counts,
--- and the open book's settings, so today's highlights are on disk.
function Blossom:flushStats()
    local stats = self.ui and self.ui.statistics
    if stats and stats.insertDB then
        local ok, err = pcall(stats.insertDB, stats)
        if not ok then logger.warn("Blossom: could not flush statistics", err) end
    end
    if self.ui and self.ui.document and self.ui.saveSettings then
        local ok, err = pcall(self.ui.saveSettings, self.ui)
        if not ok then logger.warn("Blossom: could not save book settings", err) end
    end
end

--- Runs fn(conn) on the stats DB. Returns fn's result, or nil + error.
function Blossom:withDB(fn)
    if lfs.attributes(self.db_path, "mode") ~= "file" then return nil, "missing" end
    local SQ3 = require("lua-ljsqlite3/init")
    local ok, conn = pcall(SQ3.open, self.db_path)
    if not ok or not conn then return nil, tostring(conn) end
    local ok2, result = pcall(fn, conn)
    conn:close()
    if not ok2 then
        logger.warn("Blossom: query failed", result)
        return nil, tostring(result)
    end
    return result
end

--- conn:exec returns columns (res[col][row]) with int64 cdata numbers; turn into row tables.
local function rows(res, fields)
    local out = {}
    if not res or not res[1] then return out end
    for i = 1, #res[1] do
        local row = {}
        for c, name in ipairs(fields) do
            local v = res[c][i]
            if type(v) == "cdata" then v = tonumber(v) end
            row[name] = v
        end
        out[i] = row
    end
    return out
end
Blossom.rows = rows

-- Each query is isolated so one failure only empties its own section.
local function try(conn, fn)
    local ok, result = pcall(fn, conn)
    if ok then return result end
    logger.warn("Blossom: query failed", result)
end

function Blossom:loadRaw()
    return self:withDB(function(conn)
        local raw = {}
        raw.totals = try(conn, function(c)
            local books, seconds, pages = c:rowexec(SQL_TOTALS)
            return { books = tonumber(books), seconds = tonumber(seconds), pages = tonumber(pages) }
        end)
        raw.days = try(conn, function(c)
            return rows(c:exec(SQL_DAYS), { "date", "seconds" })
        end)
        raw.books = try(conn, function(c)
            return rows(c:exec(string.format(SQL_RECENT, RECENT_BOOKS)),
                { "id", "title", "authors", "md5", "pages", "read_pages", "seconds" })
        end)
        return raw
    end)
end

function Blossom:loadPeriod(start_time, end_time)
    local result = self:withDB(function(conn)
        local list = rows(conn:exec(string.format(SQL_PERIOD_BOOKS, start_time, end_time)),
            { "id", "title", "authors", "md5", "pages", "read_pages", "seconds", "period_pages" })
        local days = conn:rowexec(string.format(SQL_PERIOD_DAYS, start_time, end_time))
        return { list = list, days = tonumber(days) }
    end) or {}
    return Data.summarizePeriod(result.list, result.days)
end

--- Month books plus each day's most-read book (for calendar covers).
function Blossom:loadMonth(y, m)
    local start_time, end_time = Data.monthBounds(y, m)
    local month = self:loadPeriod(start_time, end_time)
    local day_rows = self:withDB(function(conn)
        return rows(conn:exec(string.format(SQL_DAY_BOOKS, start_time, end_time)),
            { "date", "id", "md5", "title", "seconds" })
    end)
    month.top_by_date = Data.topBookPerDay(day_rows)
    month.spans = Data.readingSpans(day_rows)
    return month
end

function Blossom:loadBook(id)
    id = tonumber(id)
    if not id then return end
    local row = self:withDB(function(conn)
        return rows(conn:exec(string.format(SQL_BOOK, id)), { "id", "title", "authors", "md5", "pages",
            "read_pages", "seconds", "highlights", "notes", "first", "last", "days" })[1]
    end)
    if not row then return end
    local detail = Data.bookDetail(row)
    local sidecar = self:readSidecar(row.md5)
    local notes = Data.annotations({ { title = detail.title, id = detail.id,
        annotations = sidecar.annotations, bookmarks = sidecar.bookmarks } })
    detail.highlight_list = notes.highlights
    detail.bookmark_count = #notes.bookmarks
    detail.snippet = Data.snippet(sidecar.description)
    return detail
end

--- A book's annotations and description from its sidecar (and CoverBrowser's cache).
function Blossom:readSidecar(md5)
    local out = {}
    local file = self.covers and self.covers:pathFor(md5)
    if not file then return out end
    local ok, err = pcall(function()
        local doc_settings = require("docsettings"):open(file)
        out.annotations = doc_settings:readSetting("annotations")
        if not out.annotations then out.bookmarks = doc_settings:readSetting("bookmarks") end
        local props = doc_settings:readSetting("doc_props")
        out.description = props and props.description
    end)
    if not ok then logger.warn("Blossom: could not read sidecar", file, err) end
    if not out.description then
        local bim = package.loaded["bookinfomanager"]
        if bim then
            local ok2, info = pcall(bim.getBookInfo, bim, file, false)
            if ok2 and info then out.description = info.description end
        end
    end
    return out
end

function Blossom:loadYear(y)
    local start_time, end_time = Data.yearBounds(y)
    local raw = self:withDB(function(conn)
        return {
            finished_rows = rows(conn:exec(string.format(SQL_YEAR_FINISHED, start_time, end_time)),
                { "pages", "read_pages", "last" }),
            months = rows(conn:exec(string.format(SQL_YEAR_MONTHS, start_time, end_time)),
                { "month", "seconds", "pages" }),
            days = tonumber(conn:rowexec(string.format(SQL_PERIOD_DAYS, start_time, end_time))),
        }
    end)
    return Data.summarizeYear(y, raw)
end

--- Books read on `date` plus the highlights and bookmarks made that day.
function Blossom:loadDay(date)
    local day = self:loadPeriod(Data.dayBounds(date))
    day.date = date
    local books = {}
    for i, b in ipairs(day.list) do
        local sidecar = self:readSidecar(b.md5)
        books[i] = { title = b.title, id = b.id, annotations = sidecar.annotations, bookmarks = sidecar.bookmarks }
    end
    day.notes = Data.annotationsForDay(books, date)
    return day
end

--- Every book read, ordered "recent", "time" or "pages".
function Blossom:loadBooks(order)
    local list = self:withDB(function(conn)
        return rows(conn:exec(string.format(SQL_ALL_BOOKS, BOOK_ORDERS[order] or BOOK_ORDERS.recent)),
            { "id", "title", "authors", "md5", "pages", "read_pages", "seconds" })
    end) or {}
    local books = {}
    for i, row in ipairs(list) do
        row.period_pages = row.read_pages
        books[i] = Data.summarizePeriod({ row }, 0).list[1]
    end
    return books
end

--- All highlights and bookmarks from the sidecars of books in the reading history, newest first.
function Blossom:loadAllNotes()
    local books = {}
    local ok, hist = pcall(function() return require("readhistory").hist end)
    for _, item in ipairs(ok and hist or {}) do
        local file = item.file
        if file and lfs.attributes(file, "mode") == "file" then
            local ok2, err = pcall(function()
                local doc_settings = require("docsettings"):open(file)
                local props = doc_settings:readSetting("doc_props") or {}
                local annotations = doc_settings:readSetting("annotations")
                books[#books + 1] = {
                    title = (props.title and props.title ~= "") and props.title
                        or file:match("([^/]+)%.[^.]+$") or file,
                    annotations = annotations,
                    bookmarks = not annotations and doc_settings:readSetting("bookmarks") or nil,
                }
            end)
            if not ok2 then logger.warn("Blossom: could not read sidecar", file, err) end
        end
    end
    local notes = Data.annotations(books)
    local function newestFirst(list)
        table.sort(list, function(a, b) return a.datetime > b.datetime end)
        return list
    end
    return { highlights = newestFirst(notes.highlights), bookmarks = newestFirst(notes.bookmarks) }
end

-- Settings -------------------------------------------------------------------

function Blossom:getSetting(key)
    return (G_reader_settings:readSetting(SETTINGS_KEY) or {})[key]
end

function Blossom:setSetting(key, value)
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    settings[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    G_reader_settings:flush()
end

function Blossom:getGoal()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    return Data.validGoal(settings.yearly_goal)
end

function Blossom:setGoal(goal)
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    settings.yearly_goal = Data.validGoal(goal)
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    G_reader_settings:flush()
end

-- UI -------------------------------------------------------------------------

--- Opens Blossom. opts.book: go straight to the book being read.
function Blossom:show(opts)
    opts = opts or {}
    self:flushStats()
    Theme.layout.window = self:getSetting("open_as") == "window"
    local today = os.date("%Y-%m-%d")
    local raw, err = self:loadRaw()
    local stats = Data.summarize(raw, today)
    stats.db_error = err ~= nil and err ~= "missing"
    local notes = self:loadAllNotes()
    stats.notes = notes
    stats.highlights, stats.bookmarks = #notes.highlights, #notes.bookmarks
    self.covers = Covers.new()
    local start = self:getSetting("start_page") or "overview"
    local page = 1
    for i, key in ipairs(BlossomView.PAGES) do
        if key == start then page = i end
    end
    local view = BlossomView:new{
        page = page,
        stats = stats,
        hour = tonumber(os.date("%H")),
        covers = self.covers,
        loadWeek = function()
            return self:loadPeriod(Data.weekBounds(today))
        end,
        loadMonth = function(y, m) return self:loadMonth(y, m) end,
        loadYear = function(y) return self:loadYear(y) end,
        loadBook = function(id) return self:loadBook(id) end,
        loadDay = function(date) return self:loadDay(date) end,
        loadBooks = function(order) return self:loadBooks(order) end,
        loadPeriod = function(s, e) return self:loadPeriod(s, e) end,
        getGoal = function() return self:getGoal() end,
        setGoal = function(goal) self:setGoal(goal) end,
    }
    Theme.showPage(view)
    -- "This book in Blossom", or starting on the book being read: its details on top of the diary.
    if opts.book or start == "current_book" then
        local id = self:currentBookId()
        if id then
            view:openBook(id)
        elseif opts.book then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("This book has no reading statistics yet ❀"), timeout = 3 })
        end
    end
    return view
end

return Blossom
