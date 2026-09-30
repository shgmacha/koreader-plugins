local H = require("tests.harness")
local test, eq = H.test, H.eq
local Data = require("blossom_data")

local function days(list)
    local out = {}
    for _, d in ipairs(list) do out[#out + 1] = { date = d, seconds = 600 } end
    return out
end

test("fmtDuration", function()
    eq(Data.fmtDuration(nil), "0m")
    eq(Data.fmtDuration(0), "0m")
    eq(Data.fmtDuration(30), "<1m")
    eq(Data.fmtDuration(59 * 60 + 59), "59m")
    eq(Data.fmtDuration(3600), "1h 00m")
    eq(Data.fmtDuration(3 * 3600 + 5 * 60 + 20), "3h 05m")
end)

test("greeting boundaries", function()
    assert(Data.greeting(5):find("morning"))
    assert(Data.greeting(11):find("morning"))
    assert(Data.greeting(12):find("afternoon"))
    assert(Data.greeting(17):find("evening"))
    assert(Data.greeting(22):find("night owl"))
    assert(Data.greeting(3):find("night owl"))
    eq(Data.greeting(23), "Hello, night owl") -- no star
end)

test("date helpers wrap months and years", function()
    eq(Data.addDays("2026-03-01", -1), "2026-02-28")
    eq(Data.addDays("2026-12-31", 1), "2027-01-01")
    eq(Data.weekdayLabel("2026-09-30"), "We")
    eq({ Data.shiftMonth(2026, 1, -1) }, { 2025, 12 })
    eq({ Data.shiftMonth(2026, 12, 1) }, { 2027, 1 })
    eq({ Data.shiftMonth(2026, 9, 0) }, { 2026, 9 })
    local s, e = Data.monthBounds(2026, 12)
    eq(os.date("%Y-%m-%d %H:%M", s), "2026-12-01 00:00")
    eq(os.date("%Y-%m-%d %H:%M", e), "2027-01-01 00:00")
    s, e = Data.weekBounds("2026-09-30")
    eq(os.date("%Y-%m-%d %H:%M", s), "2026-09-24 00:00")
    eq(os.date("%Y-%m-%d %H:%M", e), "2026-10-01 00:00")
    assert(Data.monthTitle(2026, 9):find("2026"))
end)

test("streak alive today, from yesterday, broken, empty", function()
    local today = "2026-09-30"
    eq({ Data.streaks(days{ "2026-09-28", "2026-09-29", "2026-09-30" }, today) }, { 3, 3 })
    eq({ Data.streaks(days{ "2026-09-28", "2026-09-29" }, today) }, { 2, 2 })
    eq({ Data.streaks(days{ "2026-09-27", "2026-09-28" }, today) }, { 0, 2 })
    eq({ Data.streaks({}, today) }, { 0, 0 })
end)

test("longest streak across gaps, month ends, ignores future and zero days", function()
    local list = days{ "2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02", "2026-05-01", "2026-09-30", "2026-10-01" }
    table.insert(list, { date = "2026-09-29", seconds = 0 })
    eq({ Data.streaks(list, "2026-09-30") }, { 1, 4 })
end)

test("summarize builds week buckets, best day, flowers, recent books", function()
    local raw = {
        totals = { books = 3, seconds = 9000, pages = 300 },
        days = {
            { date = "2026-09-20", seconds = 100 },
            { date = "2026-09-25", seconds = 1200 },
            { date = "2026-09-28", seconds = 3000 },
            { date = "2026-09-30", seconds = 600 },
        },
        books = {
            { title = "Dune", authors = "Herbert", pages = 400, read_pages = 400, seconds = 7200 },
            { title = nil, authors = nil, pages = 0, read_pages = 12, seconds = 60 },
            { title = "Big", pages = 100, read_pages = 150, seconds = 5 },
        },
    }
    local s = Data.summarize(raw, "2026-09-30")
    eq(s.empty, false)
    eq(s.books, 3)
    eq(s.today_seconds, 600)
    eq(s.week_seconds, 4800)
    eq(#s.week, 7)
    eq(s.week[1].date, "2026-09-24")
    eq(s.week[7].date, "2026-09-30")
    eq(s.week[3].seconds, 0)
    eq(s.best_day_index, 5)
    eq(#s.flowers, 14)
    eq(s.flowers[14], true)
    eq(s.flowers[13], false)
    eq(s.flowers[1], false) -- 2026-09-17
    eq(s.flowers[4], true)  -- 2026-09-20
    eq(s.recent[1].finished, true)
    eq(s.recent[2].title, "Untitled")
    eq(s.recent[2].authors, "")
    eq(s.recent[2].progress, 0)
    eq(s.recent[3].progress, 1)
end)

test("summarize empty / nil input", function()
    local s = Data.summarize(nil, "2026-09-30")
    eq(s.empty, true)
    eq(s.seconds, 0)
    eq(s.streak, 0)
    eq(s.best_day_index, nil)
    eq(#s.recent, 0)
    eq(s.flowers[1], false)
end)

test("summarizePeriod totals and ordering", function()
    local p = Data.summarizePeriod({
        { title = "B", seconds = 100, period_pages = 5, pages = 10, read_pages = 10, md5 = "b" },
        { title = "A", seconds = 100, period_pages = 3, pages = 10, read_pages = 2, md5 = "a" },
        { title = "C", seconds = 900, period_pages = 40, pages = nil, read_pages = 9, md5 = "c" },
    }, 6)
    eq(p.books, 3)
    eq(p.seconds, 1100)
    eq(p.pages, 48)
    eq(p.days_read, 6)
    eq({ p.list[1].title, p.list[2].title, p.list[3].title }, { "C", "A", "B" })
    eq(p.list[3].finished, true)
    eq(p.list[1].md5, "c")
    eq(Data.summarizePeriod(nil, nil), { books = 0, days_read = 0, list = {}, pages = 0, seconds = 0 })
end)

test("affirmation is deterministic per day", function()
    eq(Data.affirmation("2026-09-30"), Data.affirmation("2026-09-30"))
    assert(type(Data.affirmation("2026-01-01")) == "string")
end)

test("summarize exposes by_date and passes ids through", function()
    local s = Data.summarize({
        days = { { date = "2026-09-30", seconds = 60 }, { date = "2026-09-30", seconds = 40 } },
        books = { { id = 7, title = "T", pages = 10, read_pages = 1, seconds = 5 } },
    }, "2026-09-30")
    eq(s.by_date, { ["2026-09-30"] = 100 })
    eq(s.recent[1].id, 7)
end)

test("level boundaries", function()
    eq({ Data.level(nil), Data.level(0), Data.level(1), Data.level(899), Data.level(900),
         Data.level(2699), Data.level(2700) }, { 0, 0, 1, 1, 2, 2, 3 })
end)

test("calendar is Sunday-first and padded to whole weeks", function()
    -- May 2026 starts on a Friday: 5 blanks + 31 days -> 6 rows.
    local cal = Data.calendar(2026, 5, { ["2026-05-02"] = 1200, ["2026-05-31"] = 5000 }, "2026-05-15")
    eq(cal.headers[1], "Su")
    eq(cal.rows, 6)
    eq(#cal.cells, 42)
    for i = 1, 5 do eq(cal.cells[i], false) end
    eq(cal.cells[6].day, 1)
    eq(cal.cells[7].level, 2)
    eq(cal.cells[20].today, true)
    eq(cal.cells[36].day, 31)
    eq(cal.cells[36].level, 3)
    eq(cal.cells[36].future, true)
    eq(cal.cells[37], false)
    -- Feb 2026 starts on Sunday, 28 days -> exactly 4 rows, no padding.
    cal = Data.calendar(2026, 2, nil, "2026-09-30")
    eq({ cal.rows, cal.cells[1].day, cal.cells[28].day }, { 4, 1, 28 })
    -- Leap February.
    local days = 0
    for _, c in ipairs(Data.calendar(2028, 2, {}, nil).cells) do if c then days = days + 1 end end
    eq(days, 29)
    eq(Data.daysInMonth(2028, 2), 29)
    eq(Data.daysInMonth(2026, 2), 28)
    eq(Data.daysInMonth(2026, 12), 31)
end)

test("year helpers", function()
    eq(Data.daysInYear(2026), 365)
    eq(Data.daysInYear(2028), 366)
    eq(Data.daysInYear(2100), 365)
    eq(Data.daysInYear(2000), 366)
    eq(Data.dayOfYear("2026-01-01"), 1)
    eq(Data.dayOfYear("2028-12-31"), 366)
    local s, e = Data.yearBounds(2026)
    eq(os.date("%Y-%m-%d %H:%M", s), "2026-01-01 00:00")
    eq(os.date("%Y-%m-%d %H:%M", e), "2027-01-01 00:00")
    eq(Data.fmtDate(nil), nil)
    eq(Data.fmtDate(0), nil)
    eq(Data.fmtDate(os.time{ year = 2026, month = 8, day = 3, hour = 12 }), "3 Aug 2026")
end)

test("goal validation", function()
    eq({ Data.validGoal(nil), Data.validGoal(0), Data.validGoal("x"), Data.validGoal("20"),
         Data.validGoal(7.9), Data.validGoal(9999) }, { 12, 12, 12, 20, 7, 365 })
end)

test("goal status: ahead, on track, behind, reached", function()
    -- 2026-07-02 is day 183 of 365 -> expected ~6.02 of 12
    eq(Data.goalStatus(8, 12, "2026-07-02").message, "1 book ahead ♡")
    eq(Data.goalStatus(10, 12, "2026-07-02").message, "3 books ahead ♡")
    eq(Data.goalStatus(6, 12, "2026-07-02").message, "right on track ❀")
    eq(Data.goalStatus(5, 12, "2026-07-02").message, "1 book behind — you've got this ☆")
    eq(Data.goalStatus(0, 24, "2026-07-02").message, "12 books behind — you've got this ☆")
    eq(Data.goalStatus(12, 12, "2026-03-01").message, "Goal reached! ♥")
    local st = Data.goalStatus(nil, nil, "2026-01-01")
    eq({ st.goal, st.finished, st.message }, { 12, 0, "right on track ❀" })
end)

test("summarizeYear counts finished books and buckets months", function()
    local y = Data.summarizeYear(2026, {
        finished_rows = { { pages = 100, read_pages = 99 }, { pages = 100, read_pages = 50 }, { pages = nil, read_pages = 5 } },
        months = { { month = "03", seconds = 600, pages = 10 }, { month = "09", seconds = 7200, pages = 90 }, { month = "13", seconds = 1 } },
        days = 21,
    })
    eq({ y.finished, y.seconds, y.pages, y.days_read, y.best_month }, { 1, 7800, 100, 21, 9 })
    eq(#y.months, 12)
    eq(y.months[3], { label = "M", seconds = 600 })
    local empty = Data.summarizeYear(2026, nil)
    eq({ empty.finished, empty.seconds, empty.best_month }, { 0, 0, nil })
end)

test("bookDetail speed, time left and missing data", function()
    local d = Data.bookDetail{ id = 3, title = "Dune", pages = 400, read_pages = 100, seconds = 7200,
        highlights = 4, notes = 1, days = 5, first = os.time{ year = 2026, month = 8, day = 3, hour = 9 },
        last = os.time{ year = 2026, month = 9, day = 29, hour = 21 } }
    eq({ d.id, d.speed, d.time_left, d.highlights, d.days, d.first, d.last, d.total_pages },
       { 3, 50, 21600, 4, 5, "3 Aug 2026", "29 Sep 2026", 400 })
    local fin = Data.bookDetail{ title = "F", pages = 100, read_pages = 100, seconds = 3600 }
    eq({ fin.finished, fin.time_left, fin.speed }, { true, nil, 100 })
    local blank = Data.bookDetail{}
    eq({ blank.title, blank.speed, blank.time_left, blank.first, blank.highlights }, { "Untitled", nil, nil, nil, 0 })
end)

test("topBookPerDay keeps each day's longest read", function()
    local top = Data.topBookPerDay({
        { date = "2026-09-01", id = 1, md5 = "a", seconds = 600 },
        { date = "2026-09-01", id = 2, md5 = "b", seconds = 1800 },
        { date = "2026-09-01", id = 3, md5 = "c", seconds = 1800 }, -- tie: first stays
        { date = "2026-09-02", id = 1, md5 = "a", seconds = 0 },
        { date = nil, id = 9, md5 = "z", seconds = 99 },
    })
    eq(top, { ["2026-09-01"] = { id = 2, md5 = "b", seconds = 1800 } })
    eq(Data.topBookPerDay(nil), {})
end)

test("calendar cells carry the day's top book", function()
    local cal = Data.calendar(2026, 9, {}, "2026-09-30", { ["2026-09-02"] = { id = 2, md5 = "b", seconds = 5 } })
    -- Sep 2026 starts on Tuesday: 2 blanks, so the 2nd is cell 4.
    eq(cal.cells[4].book, { id = 2, md5 = "b", seconds = 5 })
    eq(cal.cells[3].book, nil)
    eq(Data.calendar(2026, 9, {}, "2026-09-30").cells[4].book, nil)
end)

test("day helpers", function()
    local s, e = Data.dayBounds("2026-12-31")
    eq(os.date("%Y-%m-%d %H:%M", s), "2026-12-31 00:00")
    eq(os.date("%Y-%m-%d %H:%M", e), "2027-01-01 00:00")
    eq(Data.dayTitle("2026-09-01"), "Tuesday, 1 Sep")
    eq(Data.dayTitle("2026-09-30"), "Wednesday, 30 Sep")
end)

test("annotationsForDay: new and old sidecar formats, only that day, sorted", function()
    local r = Data.annotationsForDay({
        { title = "Dune", id = 3, annotations = {
            { datetime = "2026-09-30 21:10:00", drawer = "lighten", text = "Fear is the mind-killer.", note = "", chapter = "Ch 1", pageno = 12 },
            { datetime = "2026-09-30 08:00:00", text = "in Ch 2", chapter = "Ch 2", pageno = 40 }, -- bookmark
            { datetime = "2026-09-29 23:59:59", drawer = "underscore", text = "yesterday" },
            { datetime = "2026-09-30 07:00:00", drawer = "lighten", text = "early", note = "so true ♡", page = "/body/p[3]" },
            { text = "no date", drawer = "lighten" },
        } },
        { title = "Old", id = 4, bookmarks = {
            { datetime = "2026-09-30 12:00:00", highlighted = true, notes = "old quote", text = "my note", page = 7 },
            { datetime = "2026-09-30 13:00:00", notes = "Page 9", page = 9 },
        } },
        { title = "Nothing" },
    }, "2026-09-30")
    eq(#r.highlights, 3)
    eq({ r.highlights[1].text, r.highlights[1].note, r.highlights[1].page, r.highlights[1].time },
       { "early", "so true ♡", nil, "07:00" })
    eq({ r.highlights[2].text, r.highlights[2].note, r.highlights[2].page }, { "old quote", "my note", 7 })
    eq({ r.highlights[3].text, r.highlights[3].note, r.highlights[3].chapter, r.highlights[3].book_id },
       { "Fear is the mind-killer.", nil, "Ch 1", 3 })
    eq(#r.bookmarks, 2)
    eq({ r.bookmarks[1].title, r.bookmarks[1].page, r.bookmarks[1].chapter }, { "Dune", 40, "Ch 2" })
    eq({ r.bookmarks[2].title, r.bookmarks[2].page, r.bookmarks[2].text }, { "Old", 9, nil })
    eq(Data.annotationsForDay(nil, "2026-09-30"), { highlights = {}, bookmarks = {} })
end)

test("annotations without a date returns all, with a readable date", function()
    local r = Data.annotations({ { title = "Dune", annotations = {
        { datetime = "2026-08-03 21:10:00", drawer = "lighten", text = "a" },
        { datetime = "2026-09-30 08:00:00", drawer = "lighten", text = "b" },
        { datetime = "2026-09-01 08:00:00", text = "bm" },
    } } })
    eq({ #r.highlights, #r.bookmarks, r.highlights[1].text, r.highlights[1].date }, { 2, 1, "a", "3 Aug 2026" })
end)

test("snippet strips html, decodes entities, trims at a word", function()
    eq(Data.snippet(nil), nil)
    eq(Data.snippet("   "), nil)
    eq(Data.snippet("<p>A <b>cozy</b> story&nbsp;about&hellip;</p><p>love &amp; books.</p>"), "A cozy story about… love & books.")
    eq(Data.snippet("one &mdash; two &ndash; three"), "one — two – three")
    local long = string.rep("word ", 100)
    local s = Data.snippet(long, 30)
    eq(s, "word word word word word word…")
    -- never splits a multibyte character
    local utf = Data.snippet(string.rep("é", 40), 21)
    assert(utf:match("^[é]+…$"), utf)
end)

test("readingSpans joins nearby days per book, drops one-day reads", function()
    local rows = {}
    local function r(date, id, title) rows[#rows + 1] = { date = date, id = id, title = title, seconds = 60 } end
    r("2026-09-01", 1, "Happy Place"); r("2026-09-02", 1, "Happy Place"); r("2026-09-04", 1, "Happy Place") -- gap of 1 day joins
    r("2026-09-10", 1, "Happy Place")                                                                   -- alone: dropped
    r("2026-09-03", 2, "Anathema"); r("2026-09-05", 2, "Anathema")
    r("2026-09-07", 3, "Solo")
    rows[#rows + 1] = { date = "2026-09-08", id = 3, title = "Solo", seconds = 0 } -- no reading
    local spans = Data.readingSpans(rows)
    eq(spans, {
        { id = 1, title = "Happy Place", from = "2026-09-01", to = "2026-09-04",
          day_seconds = { ["2026-09-01"] = 60, ["2026-09-02"] = 60, ["2026-09-04"] = 60 } },
        { id = 2, title = "Anathema", from = "2026-09-03", to = "2026-09-05",
          day_seconds = { ["2026-09-03"] = 60, ["2026-09-05"] = 60 } },
    })
    eq(Data.readingSpans(rows, 2, 0)[1].to, "2026-09-02") -- no gaps allowed
    eq(Data.readingSpans(nil), {})
    eq(Data.daysBetween("2026-02-27", "2026-03-02"), 3)
end)

test("weekLanes clips spans to the week and stacks overlaps", function()
    local spans = {
        { id = 1, title = "A", from = "2026-08-28", to = "2026-09-03", -- starts before the week
          day_seconds = { ["2026-08-29"] = 999, ["2026-08-30"] = 60, ["2026-09-03"] = 120 } },
        { id = 2, title = "B", from = "2026-09-01", to = "2026-09-02" }, -- overlaps A -> lane 2
        { id = 3, title = "C", from = "2026-09-04", to = "2026-09-12" }, -- after A ends -> lane 1, runs on
        { id = 4, title = "D", from = "2026-09-02", to = "2026-09-03" }, -- A and B busy -> no lane
    }
    local lanes = Data.weekLanes(spans, "2026-08-30", 2) -- Sun 30 Aug .. Sat 5 Sep
    eq(#lanes, 3)
    eq({ lanes[1].title, lanes[1].lane, lanes[1].col_from, lanes[1].col_to, lanes[1].continues_left }, { "A", 1, 1, 5, true })
    eq(lanes[1].seconds, 180) -- only the days inside this week
    eq(lanes[2].seconds, 0)
    eq({ lanes[2].title, lanes[2].lane, lanes[2].col_from, lanes[2].col_to }, { "B", 2, 3, 4 })
    eq({ lanes[3].title, lanes[3].lane, lanes[3].col_from, lanes[3].col_to, lanes[3].continues_right }, { "C", 1, 6, 7, true })
    eq(Data.weekLanes(spans, "2026-10-04", 2), {})
    eq(Data.calendar(2026, 9, {}, "2026-09-30").start, "2026-08-30")
end)

test("streakRange ends today when read today, else yesterday", function()
    eq({ Data.streakRange({ ["2026-09-30"] = 60 }, "2026-09-30", 3) }, { "2026-09-28", "2026-09-30" })
    eq({ Data.streakRange({}, "2026-09-30", 2) }, { "2026-09-28", "2026-09-29" })
    eq(Data.streakRange({}, "2026-09-30", 0), nil)
end)

test("cleanQuote strips the highlight's own quote marks", function()
    eq(Data.cleanQuote('"Hello there."'), "Hello there.")
    eq(Data.cleanQuote("  “Curly,” she said  "), "Curly,” she said") -- only the outer marks go
    eq(Data.cleanQuote("‘single’"), "single")
    eq(Data.cleanQuote("«guillemets»"), "guillemets")
    eq(Data.cleanQuote('"“double wrapped”"'), "double wrapped")
    eq(Data.cleanQuote("It's fine"), "It's fine") -- inner apostrophes stay
    eq(Data.cleanQuote(nil), "")
    eq(Data.cleanQuote('""'), "")
end)

H.done()
