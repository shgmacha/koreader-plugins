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

-- Collections (KOReader collections → Goodreads shelves)
local function c(...) return { collection_shelves = { ... } } end

test("collections: names map to shelves; anything else is its own shelf; overrides", function()
    eq(Plan.collectionShelf("To Be Read"), "to-read")
    eq(Plan.collectionShelf("TBR"), "to-read")
    eq(Plan.collectionShelf("Want to read!"), "to-read")
    eq(Plan.collectionShelf("Currently Reading"), "currently-reading")
    eq(Plan.collectionShelf("DNF"), "did-not-finish")
    eq(Plan.collectionShelf("Finished"), "read")
    eq(Plan.collectionShelf("favorites"), "favorites")
    eq(Plan.collectionShelf("Cozy Autumn ♡"), "cozy-autumn")
    eq(Plan.collectionShelf("favorites", "off"), nil)
    eq(Plan.collectionShelf("Stuff", "to-read"), "to-read")
    eq(Plan.collectionShelf("Stuff", "auto"), "stuff")
end)

test("collections: unstarted TBR book → Want to Read", function()
    eq(plan({}, {}, c("to-read")), { { type = "shelf", shelf = "to-read" } })
    eq(plan({ pct = 0 }, { pushed_shelf = "to-read" }, c("to-read")), {})
end)

test("collections: reading status always wins over TBR", function()
    eq(plan({ pct = 5 }, { pushed_shelf = "to-read" }, c("to-read")),
        { { type = "shelf", shelf = "currently-reading" }, { type = "progress", pct = 5 } })
    eq(plan({ pct = 100, status = "complete" }, { pushed_shelf = "currently-reading" }, c("to-read")),
        { { type = "shelf", shelf = "read" } })
    eq(plan({}, { pushed_shelf = "currently-reading" }, c("to-read")), {}) -- started earlier, 0% now: keep
end)

test("collections: a shelf picked by hand isn't overridden by a collection", function()
    eq(plan({}, { pinned_shelf = "did-not-finish", pushed_shelf = "did-not-finish" }, c("to-read")), {})
end)

test("collections: two status collections → the stronger one (DNF over TBR)", function()
    eq(plan({}, {}, c("to-read", "did-not-finish")), { { type = "shelf", shelf = "did-not-finish" } })
    -- moved from TBR to DNF later, still unstarted
    eq(plan({}, { pushed_shelf = "to-read" }, c("did-not-finish")), { { type = "shelf", shelf = "did-not-finish" } })
end)

test("collections: custom shelves are added once, alongside the status", function()
    eq(plan({ pct = 30 }, { pushed_shelf = "currently-reading", pushed_pct = 30 }, c("favorites")),
        { { type = "shelf", shelf = "favorites", custom = true } })
    eq(plan({ pct = 30 }, { pushed_shelf = "currently-reading", pushed_pct = 30, collections_sent = { "favorites" } }, c("favorites")), {})
end)

test("collections: leaving a collection removes its custom shelf (only ones we added)", function()
    eq(plan({}, { collections_sent = { "favorites", "cozy" } }, c("cozy")), { { type = "unshelf", shelf = "favorites" } })
    -- status shelves are never removed
    eq(plan({}, { pushed_shelf = "to-read" }, c()), {})
end)

test("collections: custom shelves still sync for finished and abandoned books", function()
    eq(plan({ status = "complete" }, { pushed_shelf = "read" }, c("favorites")), { { type = "shelf", shelf = "favorites", custom = true } })
    eq(plan({ pct = 40, status = "abandoned" }, {}, c("favorites")), { { type = "shelf", shelf = "favorites", custom = true } })
end)

H.done()
