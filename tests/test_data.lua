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

H.done()
