--[[--
Pure data helpers for Blossom: no KOReader modules, so they can be unit-tested
with plain LuaJIT. Dates are local "YYYY-MM-DD" strings.
--]]

local Data = {}

Data.FINISHED_AT = 0.98
Data.DEFAULT_GOAL = 12
Data.MONTH_LETTERS = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }
Data.WEEKDAYS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

Data.AFFIRMATIONS = {
    "Every page is a petal ❀",
    "Reading is self-care ♡",
    "One more chapter, darling ☆",
    "Your little library is blooming ❀",
    "Soft hours, happy pages ♡",
    "Cozy reader energy ❀",
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

function Data.yearBounds(y)
    return os.time{ year = y, month = 1, day = 1, hour = 0 },
           os.time{ year = y + 1, month = 1, day = 1, hour = 0 }
end

function Data.daysInYear(y)
    return ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 366 or 365
end

function Data.daysInMonth(y, m)
    return tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0, hour = 12 }))
end

function Data.dayOfYear(s)
    return tonumber(os.date("%j", noon(s)))
end

--- "3 Aug 2026" from an epoch, nil for nil.
function Data.fmtDate(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return end
    local out = os.date("%d %b %Y", epoch):gsub("^0", "")
    return out
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
        id = tonumber(row.id),
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
    stats.by_date = by_date
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

-- Calendar ---------------------------------------------------------------------

--- Shade level for a day: 0 none, 1 under 15 min, 2 under 45 min, 3 more.
function Data.level(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return 0 end
    if seconds < 15 * 60 then return 1 end
    if seconds < 45 * 60 then return 2 end
    return 3
end

--- rows = {{date, id, md5, seconds}} → { [date] = {id, md5, seconds} } keeping each day's longest read.
function Data.topBookPerDay(rows)
    local top = {}
    for _, row in ipairs(rows or {}) do
        local seconds = tonumber(row.seconds) or 0
        local best = top[row.date]
        if row.date and seconds > 0 and (not best or seconds > best.seconds) then
            top[row.date] = { id = tonumber(row.id), md5 = row.md5, seconds = seconds }
        end
    end
    return top
end

--- Sunday-first month grid; `false` cells pad the first and last weeks.
--- top_by_date (optional) adds the day's most-read book to each cell.
function Data.calendar(y, m, by_date, today, top_by_date)
    by_date = by_date or {}
    top_by_date = top_by_date or {}
    local cells = {}
    local first_wday = os.date("*t", os.time{ year = y, month = m, day = 1, hour = 12 }).wday
    for _ = 1, first_wday - 1 do cells[#cells + 1] = false end
    for d = 1, Data.daysInMonth(y, m) do
        local date = string.format("%04d-%02d-%02d", y, m, d)
        local seconds = by_date[date] or 0
        cells[#cells + 1] = {
            day = d,
            date = date,
            seconds = seconds,
            level = Data.level(seconds),
            today = date == today,
            future = today ~= nil and date > today,
            book = top_by_date[date],
        }
    end
    while #cells % 7 ~= 0 do cells[#cells + 1] = false end
    return { headers = Data.WEEKDAYS, cells = cells, rows = #cells / 7 }
end

-- Yearly goal ----------------------------------------------------------------

function Data.validGoal(goal)
    goal = tonumber(goal)
    if not goal or goal < 1 then return Data.DEFAULT_GOAL end
    return math.floor(math.min(goal, 365))
end

local function books(n)
    return n == 1 and "1 book" or string.format("%d books", n)
end

--- Compares finished books with where an even pace would be today.
function Data.goalStatus(finished, goal, today)
    goal = Data.validGoal(goal)
    finished = tonumber(finished) or 0
    local y = Data.parseDate(today)
    local expected = goal * Data.dayOfYear(today) / Data.daysInYear(y)
    local diff = finished - expected
    local message
    if finished >= goal then
        message = "Goal reached! ♥"
    elseif diff >= 1 then
        message = books(math.floor(diff)) .. " ahead ♡"
    elseif diff > -1 then
        message = "right on track ❀"
    else
        message = books(math.floor(-diff)) .. " behind — you've got this ☆"
    end
    return { goal = goal, finished = finished, expected = expected, diff = diff, message = message }
end

--- raw = { finished_rows = {{pages, read_pages}}, months = {{month = "09", seconds, pages}}, days = n }
function Data.summarizeYear(y, raw)
    raw = raw or {}
    local year = { year = y, finished = 0, seconds = 0, pages = 0, days_read = tonumber(raw.days) or 0, months = {} }
    for _, row in ipairs(raw.finished_rows or {}) do
        if Data.progress(row.read_pages, row.pages) >= Data.FINISHED_AT then
            year.finished = year.finished + 1
        end
    end
    for i = 1, 12 do year.months[i] = { label = Data.MONTH_LETTERS[i], seconds = 0 } end
    for _, row in ipairs(raw.months or {}) do
        local month = year.months[tonumber(row.month)]
        if month then
            month.seconds = month.seconds + (tonumber(row.seconds) or 0)
            year.seconds = year.seconds + (tonumber(row.seconds) or 0)
            year.pages = year.pages + (tonumber(row.pages) or 0)
        end
    end
    local best = 0
    for i, month in ipairs(year.months) do
        if month.seconds > best then best, year.best_month = month.seconds, i end
    end
    return year
end

-- Book detail ------------------------------------------------------------------

function Data.bookDetail(row)
    local b = book(row)
    local seconds = b.seconds
    local read = tonumber(row.read_pages) or 0
    local total = tonumber(row.pages) or 0
    b.read_pages = read
    b.total_pages = total
    b.highlights = tonumber(row.highlights) or 0
    b.notes = tonumber(row.notes) or 0
    b.days = tonumber(row.days) or 0
    b.first = Data.fmtDate(row.first)
    b.last = Data.fmtDate(row.last)
    if seconds >= 60 and read > 0 then
        b.speed = math.floor(read / (seconds / 3600) + 0.5)
    end
    if not b.finished and read > 0 and total > read and seconds > 0 then
        b.time_left = math.floor((total - read) * seconds / read)
    end
    return b
end

return Data
