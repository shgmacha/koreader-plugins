-- Blossom Reads: pure sync decisions (spec tables c and f).
local H = require("tests.harness")
local test, eq = H.test, H.eq
local Plan = require("blossomreads_plan")

local function plan(now, saved, opts) return Plan.planBook(now, saved, opts) end

test("book: unopened (0%) sends nothing", function()
    eq(plan({ pct = 0 }, {}), {})
    eq(plan({}, {}), {})
end)

test("book: first progress → Currently Reading + progress", function()
    eq(plan({ pct = 12 }, {}), { { type = "shelf", shelf = "currently-reading" }, { type = "progress", pct = 12 } })
end)

test("book: same progress again sends nothing (re-run safe)", function()
    eq(plan({ pct = 12 }, { pushed_pct = 12, pushed_shelf = "currently-reading" }), {})
end)

test("book: more progress → progress only", function()
    eq(plan({ pct = 47 }, { pushed_pct = 12, pushed_shelf = "currently-reading" }), { { type = "progress", pct = 47 } })
end)

test("book: progress never moves backwards (re-reading, other device ahead)", function()
    eq(plan({ pct = 30 }, { pushed_pct = 47, pushed_shelf = "currently-reading" }), {})
end)

test("book: marked complete → Read, no progress post", function()
    eq(plan({ pct = 97, status = "complete" }, { pushed_pct = 47, pushed_shelf = "currently-reading" }),
        { { type = "shelf", shelf = "read" } })
end)

test("book: already Read → nothing more, even if progress changes", function()
    eq(plan({ pct = 100, status = "complete" }, { pushed_shelf = "read" }), {})
    eq(plan({ pct = 20 }, { pushed_shelf = "read", pushed_pct = 10 }), {})
end)

test("book: 99% marks Read only when that setting is on", function()
    eq(plan({ pct = 99 }, { pushed_pct = 90, pushed_shelf = "currently-reading" }), { { type = "progress", pct = 99 } })
    eq(plan({ pct = 99 }, { pushed_pct = 90, pushed_shelf = "currently-reading" }, { complete_at_99 = true }),
        { { type = "shelf", shelf = "read" } })
end)

test("book: abandoned sends nothing (DNF is picked by hand)", function()
    eq(plan({ pct = 40, status = "abandoned" }, {}), {})
end)

test("book: a shelf picked by hand isn't overridden by Currently Reading, progress still syncs", function()
    eq(plan({ pct = 15 }, { pinned_shelf = "to-read" }), { { type = "progress", pct = 15 } })
end)

test("book: finishing still marks Read over a hand-picked shelf", function()
    eq(plan({ pct = 100, status = "complete" }, { pinned_shelf = "to-read" }), { { type = "shelf", shelf = "read" } })
end)

test("book: fractional percent is floored", function()
    eq(plan({ pct = 12.9 }, { pushed_shelf = "currently-reading" }), { { type = "progress", pct = 12 } })
end)

-- Goal: decideGoal(blossom, goodreads, synced)
test("goal: couldn't fetch Goodreads → skip", function()
    eq(Plan.decideGoal(20, nil, 20), { action = "skip" })
end)

test("goal: no Goodreads challenge yet → push Blossom's goal", function()
    eq(Plan.decideGoal(20, 0, nil), { action = "push", value = 20 })
    eq(Plan.decideGoal(nil, 0, nil), { action = "skip" })
end)

test("goal: Blossom never set → take Goodreads'", function()
    eq(Plan.decideGoal(nil, 24, nil), { action = "pull", value = 24, synced = 24 })
end)

test("goal: equal → adopt", function()
    eq(Plan.decideGoal(24, 24, nil), { action = "adopt", synced = 24 })
end)

test("goal: only Blossom changed → push to Goodreads", function()
    eq(Plan.decideGoal(30, 24, 24), { action = "push", value = 30 })
end)

test("goal: only Goodreads changed → pull into Blossom", function()
    eq(Plan.decideGoal(24, 40, 24), { action = "pull", value = 40, synced = 40 })
end)

test("goal: both changed → Goodreads wins", function()
    eq(Plan.decideGoal(30, 40, 24), { action = "pull", value = 40, synced = 40 })
end)

test("goal: first sync with different goals → Goodreads wins", function()
    eq(Plan.decideGoal(12, 50, nil), { action = "pull", value = 50, synced = 50 })
end)

test("goal: a Goodreads goal over 365 is capped in Blossom and doesn't bounce back", function()
    local first = Plan.decideGoal(12, 400, nil)
    eq(first, { action = "pull", value = 365, synced = 400 })
    -- next run: Blossom holds 365, Goodreads still 400 → nothing to push
    eq(Plan.decideGoal(365, 400, 400), { action = "adopt", synced = 400 })
end)

H.done()
