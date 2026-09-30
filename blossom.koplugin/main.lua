--[[--
Blossom ✿ a cute reading diary for KOReader.

Reads the built-in Statistics plugin's database (read-only) and shows an
overview, a weekly bloom chart, recent-book progress and a monthly shelf of
covers in a soft, grayscale-friendly style.
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local BlossomView = require("blossom_view")
local Covers = require("blossom_covers")
local Data = require("blossom_data")

local RECENT_BOOKS = 6

local SQL_TOTALS = [[
    SELECT count(*), sum(total_read_time), sum(total_read_pages)
    FROM book WHERE total_read_time > 0;]]

local SQL_DAYS = [[
    SELECT date(start_time, 'unixepoch', 'localtime') AS d, sum(duration)
    FROM page_stat_data GROUP BY d ORDER BY d;]]

local SQL_RECENT = [[
    SELECT title, authors, md5, pages, total_read_pages, total_read_time
    FROM book WHERE total_read_time > 0
    ORDER BY last_open DESC LIMIT %d;]]

local SQL_PERIOD_BOOKS = [[
    SELECT b.title, b.authors, b.md5, b.pages, b.total_read_pages,
           sum(p.duration), count(DISTINCT p.page)
    FROM page_stat_data p JOIN book b ON b.id = p.id_book
    WHERE p.start_time >= %d AND p.start_time < %d
    GROUP BY b.id ORDER BY sum(p.duration) DESC;]]

local SQL_PERIOD_DAYS = [[
    SELECT count(DISTINCT date(start_time, 'unixepoch', 'localtime'))
    FROM page_stat_data WHERE start_time >= %d AND start_time < %d;]]

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
end

function Blossom:addToMainMenu(menu_items)
    menu_items.blossom = {
        text = _("✿ Blossom reading diary"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Blossom:onBlossomShow()
    self:show()
    return true
end

-- Database -------------------------------------------------------------------

--- Saves page stats the Statistics plugin still holds in memory, so today counts.
function Blossom:flushStats()
    local stats = self.ui and self.ui.statistics
    if stats and stats.insertDB then
        local ok, err = pcall(stats.insertDB, stats)
        if not ok then logger.warn("Blossom: could not flush statistics", err) end
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
                { "title", "authors", "md5", "pages", "read_pages", "seconds" })
        end)
        return raw
    end)
end

function Blossom:loadPeriod(start_time, end_time)
    local result = self:withDB(function(conn)
        local list = rows(conn:exec(string.format(SQL_PERIOD_BOOKS, start_time, end_time)),
            { "title", "authors", "md5", "pages", "read_pages", "seconds", "period_pages" })
        local days = conn:rowexec(string.format(SQL_PERIOD_DAYS, start_time, end_time))
        return { list = list, days = tonumber(days) }
    end) or {}
    return Data.summarizePeriod(result.list, result.days)
end

-- UI -------------------------------------------------------------------------

function Blossom:show()
    self:flushStats()
    local today = os.date("%Y-%m-%d")
    local raw, err = self:loadRaw()
    local stats = Data.summarize(raw, today)
    stats.db_error = err ~= nil and err ~= "missing"
    UIManager:show(BlossomView:new{
        stats = stats,
        hour = tonumber(os.date("%H")),
        covers = Covers.new(),
        loadWeek = function()
            return self:loadPeriod(Data.weekBounds(today))
        end,
        loadMonth = function(y, m)
            return self:loadPeriod(Data.monthBounds(y, m))
        end,
    }, "flashui")
end

return Blossom
