--[[--
Pure data helpers for Blossom: no KOReader modules, so they can be unit-tested
with plain LuaJIT. Dates are local "YYYY-MM-DD" strings.
--]]

local Data = {}

Data.FINISHED_AT = 0.98
Data.WEEKDAYS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

Data.AFFIRMATIONS = {
    "Every page is a petal ✿",
    "Reading is self-care ♡",
    "One more chapter, darling ☆",
    "Your little library is blooming ❀",
    "Soft hours, happy pages ♡",
    "Cozy reader energy ✿",
    "Stories look good on you ☆",
}

function Data.fmtDuration(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec <= 0 then return "0m" end
    if sec < 60 then return "<1m" end
    local minutes = math.floor(sec / 60)
    if minutes < 60 then return string.format("%dm", minutes) end
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

function Data.greeting(hour)
    hour = tonumber(hour) or 12
    if hour >= 5 and hour < 12 then return "Good morning, bookworm ♡" end
    if hour >= 12 and hour < 17 then return "Good afternoon, sweet reader ♡" end
    if hour >= 17 and hour < 22 then return "Good evening, darling ♡" end
    return "Hello, night owl ☆"
end

function Data.affirmation(today)
    local y, m, d = Data.parseDate(today)
    local t = os.time{ year = y, month = m, day = d, hour = 12 }
    local yday = tonumber(os.date("%j", t))
    return Data.AFFIRMATIONS[yday % #Data.AFFIRMATIONS + 1]
end

-- Dates ----------------------------------------------------------------------

function Data.parseDate(s)
    local y, m, d = s:match("^(%d+)-(%d+)-(%d+)$")
    return tonumber(y), tonumber(m), tonumber(d)
end

-- Noon avoids DST edges when stepping days.
local function noon(s)
    local y, m, d = Data.parseDate(s)
    return os.time{ year = y, month = m, day = d, hour = 12 }
end

function Data.addDays(s, n)
    local y, m, d = Data.parseDate(s)
    return os.date("%Y-%m-%d", os.time{ year = y, month = m, day = d + n, hour = 12 })
end

function Data.weekdayLabel(s)
    return Data.WEEKDAYS[os.date("*t", noon(s)).wday]
end

--- Epoch bounds [start, stop) of the 7 days ending today (local time).
function Data.weekBounds(today)
    local y, m, d = Data.parseDate(today)
    return os.time{ year = y, month = m, day = d - 6, hour = 0 },
           os.time{ year = y, month = m, day = d + 1, hour = 0 }
end

function Data.monthBounds(y, m)
    return os.time{ year = y, month = m, day = 1, hour = 0 },
           os.time{ year = y, month = m + 1, day = 1, hour = 0 }
end

function Data.shiftMonth(y, m, delta)
    local idx = y * 12 + (m - 1) + delta
    return math.floor(idx / 12), idx % 12 + 1
end

function Data.monthTitle(y, m)
    return os.date("%B %Y", os.time{ year = y, month = m, day = 1, hour = 12 })
end

-- Aggregation ------------------------------------------------------------------

function Data.progress(read_pages, pages)
    pages = tonumber(pages)
    if not pages or pages <= 0 then return 0 end
    return math.max(0, math.min(1, (tonumber(read_pages) or 0) / pages))
end

--- days: list of { date, seconds } ascending. Returns current, longest.
function Data.streaks(days, today)
    local set, dates = {}, {}
    for _, day in ipairs(days) do
        if (day.seconds or 0) > 0 and day.date <= today and not set[day.date] then
            set[day.date] = true
            dates[#dates + 1] = day.date
        end
    end
    table.sort(dates)

    local longest, run, prev = 0, 0, nil
    for _, d in ipairs(dates) do
        run = (prev and Data.addDays(prev, 1) == d) and run + 1 or 1
        longest = math.max(longest, run)
        prev = d
    end

    -- A streak stays alive until the end of today even if today has no reading yet.
    local current, d = 0, today
    if not set[d] then d = Data.addDays(today, -1) end
    while set[d] do
        current = current + 1
        d = Data.addDays(d, -1)
    end
    return current, longest
end

local function book(row)
    local progress = Data.progress(row.read_pages, row.pages)
    return {
        title = (row.title and row.title ~= "") and row.title or "Untitled",
        authors = row.authors or "",
        md5 = row.md5,
        seconds = tonumber(row.seconds) or 0,
        pages = tonumber(row.period_pages) or 0,
        progress = progress,
        finished = progress >= Data.FINISHED_AT,
    }
end

--- raw = { totals = {books, seconds, pages}, days = {{date, seconds}}, books = {...} }
function Data.summarize(raw, today)
    raw = raw or {}
    local totals = raw.totals or {}
    local days = raw.days or {}
    local by_date = {}
    for _, day in ipairs(days) do
        by_date[day.date] = (by_date[day.date] or 0) + (tonumber(day.seconds) or 0)
    end

    local stats = {
        books = tonumber(totals.books) or 0,
        seconds = tonumber(totals.seconds) or 0,
        pages = tonumber(totals.pages) or 0,
        today = today,
        today_seconds = by_date[today] or 0,
        week = {},
        flowers = {},
        recent = {},
    }
    stats.streak, stats.longest_streak = Data.streaks(days, today)

    local week_seconds, best = 0, 0
    for i = 1, 7 do
        local d = Data.addDays(today, i - 7)
        local secs = by_date[d] or 0
        stats.week[i] = { date = d, label = Data.weekdayLabel(d), seconds = secs }
        week_seconds = week_seconds + secs
        if secs > best then best, stats.best_day_index = secs, i end
    end
    stats.week_seconds = week_seconds

    for i = 1, 14 do
        stats.flowers[i] = (by_date[Data.addDays(today, i - 14)] or 0) > 0
    end

    for i, row in ipairs(raw.books or {}) do
        stats.recent[i] = book(row)
    end

    stats.empty = stats.seconds == 0 and next(by_date) == nil and #stats.recent == 0
    return stats
end

--- Books read in a period (week or month), most time first.
function Data.summarizePeriod(rows, days_read)
    local period = { seconds = 0, pages = 0, days_read = tonumber(days_read) or 0, list = {} }
    for i, row in ipairs(rows or {}) do
        local b = book(row)
        period.list[i] = b
        period.seconds = period.seconds + b.seconds
        period.pages = period.pages + b.pages
    end
    table.sort(period.list, function(a, b)
        if a.seconds ~= b.seconds then return a.seconds > b.seconds end
        return a.title < b.title
    end)
    period.books = #period.list
    return period
end

return Data
