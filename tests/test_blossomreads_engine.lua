-- Blossom Reads: sync engine with a fake Goodreads.
local H = require("tests.harness")
local test, eq = H.test, H.eq
local Engine = require("blossomreads_engine")

-- Fake api: records calls; fail[gid] = error code for that book's next call(s).
local function fakeApi(o)
    o = o or {}
    local api = { calls = {}, fail = o.fail or {}, ch = o.challenge, goal_err = o.goal_err }
    local function call(name, gid, value)
        api.calls[#api.calls + 1] = name .. ":" .. tostring(gid) .. "=" .. tostring(value)
        local err = api.fail[gid]
        if err then return nil, err end
        return value
    end
    function api:setShelf(gid, shelf)
        local ok, err = call("shelf", gid, shelf)
        if ok then return true end
        return nil, err
    end
    function api:progress(gid, pct) return call("progress", gid, pct) end
    function api:unshelf(gid, shelf)
        local ok, err = call("unshelf", gid, shelf)
        if ok then return true end
        return nil, err
    end
    function api:challenge()
        if self.ch_err then return nil, self.ch_err end
        return self.ch and { goal = self.ch.goal, read = self.ch.read }
    end
    function api:setGoal(n)
        self.calls[#self.calls + 1] = "goal=" .. n
        if self.goal_err then return nil, self.goal_err end
        return n
    end
    return api
end

local function books()
    return { ["/b/dune.epub"] = { gid = "1" }, ["/b/emma.epub"] = { gid = "2" }, ["/b/new.epub"] = {} }
end

test("engine: pushes shelf + progress, then a re-run sends nothing", function()
    local api, b = fakeApi(), books()
    local items = { { file = "/b/dune.epub", now = { pct = 47 } } }
    local s = Engine.run{ api = api, books = b, items = items, time = 100 }
    eq({ s.books, s.shelved, s.pushed, s.failed, s.changed }, { 1, 1, 1, 0, true })
    eq(api.calls, { "shelf:1=currently-reading", "progress:1=47" })
    eq(b["/b/dune.epub"], { gid = "1", pushed_shelf = "currently-reading", pushed_pct = 47, synced_at = 100 })
    api.calls = {}
    s = Engine.run{ api = api, books = b, items = items }
    eq({ #api.calls, s.changed }, { 0, false })
end)

test("engine: a failed post keeps the old state so the next run retries it", function()
    local api, b = fakeApi{ fail = { ["1"] = "server" } }, books()
    local items = { { file = "/b/dune.epub", now = { pct = 47 } }, { file = "/b/emma.epub", now = { pct = 10 } } }
    local s = Engine.run{ api = api, books = b, items = items }
    eq({ s.failed, s.shelved, s.error }, { 1, 1, nil }) -- emma still synced
    eq(b["/b/dune.epub"].pushed_pct, nil)
    api.fail = {}
    api.calls = {}
    Engine.run{ api = api, books = b, items = items }
    eq(api.calls, { "shelf:1=currently-reading", "progress:1=47" }) -- emma already done
end)

test("engine: sign-in page stops the run and reports 'signin'", function()
    local api = fakeApi{ fail = { ["1"] = "signin" } }
    local s = Engine.run{ api = api, books = books(), items = {
        { file = "/b/dune.epub", now = { pct = 5 } }, { file = "/b/emma.epub", now = { pct = 5 } } } }
    eq({ s.error, #api.calls }, { "signin", 1 })
end)

test("engine: firewall block stops the run as 'blocked' (session untouched by the engine)", function()
    local s = Engine.run{ api = fakeApi{ fail = { ["1"] = "blocked" } }, books = books(),
        items = { { file = "/b/dune.epub", now = { pct = 5 } } } }
    eq(s.error, "blocked")
end)

test("engine: unlinked books and missing entries are skipped", function()
    local api = fakeApi()
    Engine.run{ api = api, books = books(), items = { { file = "/b/new.epub", now = { pct = 5 } }, { file = "/b/gone.epub", now = { pct = 5 } } } }
    eq(#api.calls, 0)
end)

test("engine: finishing marks Read, records 100% and clears a hand-picked shelf", function()
    local b = { ["/b/dune.epub"] = { gid = "1", pushed_shelf = "to-read", pinned_shelf = "to-read" } }
    Engine.run{ api = fakeApi(), books = b, items = { { file = "/b/dune.epub", now = { pct = 100, status = "complete" } } } }
    eq({ b["/b/dune.epub"].pushed_shelf, b["/b/dune.epub"].pushed_pct, b["/b/dune.epub"].pinned_shelf }, { "read", 100, nil })
end)

local function goal(B, synced)
    local g = { value = B, synced = synced }
    g.get = function() return g.value end
    g.set = function(n) g.value = n end
    return g
end

test("engine/goal: Blossom changed → pushed to Goodreads", function()
    local api, g = fakeApi{ challenge = { goal = 24, read = 9 } }, goal(30, 24)
    local s = Engine.run{ api = api, books = {}, items = {}, goal = g }
    eq({ api.calls, s.synced, s.goal.action, s.challenge.goal, s.changed }, { { "goal=30" }, 30, "push", 30, true })
end)

test("engine/goal: Goodreads changed → written into Blossom", function()
    local g = goal(24, 24)
    local s = Engine.run{ api = fakeApi{ challenge = { goal = 40, read = 9 } }, books = {}, items = {}, goal = g }
    eq({ g.value, s.synced, s.goal.action }, { 40, 40, "pull" })
end)

test("engine/goal: equal goals → nothing written, synced recorded", function()
    local api, g = fakeApi{ challenge = { goal = 24, read = 9 } }, goal(24, nil)
    local s = Engine.run{ api = api, books = {}, items = {}, goal = g }
    eq({ #api.calls, s.synced, s.goal, s.changed }, { 0, 24, nil, false })
end)

test("engine/goal: challenge unreachable → goal skipped, books still synced", function()
    local api = fakeApi()
    api.ch_err = "server"
    local s = Engine.run{ api = api, books = books(), items = { { file = "/b/dune.epub", now = { pct = 5 } } }, goal = goal(30, 24) }
    eq({ s.shelved, s.synced, s.error }, { 1, nil, nil })
end)

test("engine/goal: failed goal push keeps synced as it was", function()
    local s = Engine.run{ api = fakeApi{ challenge = { goal = 24 }, goal_err = "server" }, books = {}, items = {}, goal = goal(30, 24) }
    eq({ s.synced, s.failed }, { nil, 1 })
end)

test("engine/collections: TBR + favorites for an unstarted book, then nothing on re-run", function()
    local api, b = fakeApi(), books()
    local items = { { file = "/b/dune.epub", now = {}, shelves = { "to-read", "favorites" } } }
    local s = Engine.run{ api = api, books = b, items = items }
    eq(api.calls, { "shelf:1=to-read", "shelf:1=favorites" })
    eq({ b["/b/dune.epub"].pushed_shelf, b["/b/dune.epub"].collections_sent, s.books, s.shelved }, { "to-read", { "favorites" }, 1, 2 })
    api.calls = {}
    Engine.run{ api = api, books = b, items = items }
    eq(api.calls, {})
end)

test("engine/collections: leaving favorites takes it off the shelf; a failed removal is retried", function()
    local b = { ["/b/dune.epub"] = { gid = "1", pushed_shelf = "to-read", collections_sent = { "favorites" } } }
    local api = fakeApi{ fail = { ["1"] = "server" } }
    local items = { { file = "/b/dune.epub", now = {}, shelves = { "to-read" } } }
    Engine.run{ api = api, books = b, items = items }
    eq(b["/b/dune.epub"].collections_sent, { "favorites" })
    api.fail, api.calls = {}, {}
    Engine.run{ api = api, books = b, items = items }
    eq({ api.calls, b["/b/dune.epub"].collections_sent }, { { "unshelf:1=favorites" }, nil })
end)

test("engine/collections: starting a TBR book moves it to Currently Reading", function()
    local b = { ["/b/dune.epub"] = { gid = "1", pushed_shelf = "to-read" } }
    local api = fakeApi()
    Engine.run{ api = api, books = b, items = { { file = "/b/dune.epub", now = { pct = 3 }, shelves = { "to-read" } } } }
    eq(api.calls, { "shelf:1=currently-reading", "progress:1=3" })
end)

H.done()
