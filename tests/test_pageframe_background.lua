-- Page Frame: the background runner (a copy of Goodreads Sync's), with a stand-in for KOReader's ffi/util (plain LuaJIT).
local H = require("tests.harness")
package.path = "./pageframe.koplugin/?.lua;" .. package.path
local test, eq = H.test, H.eq

local scheduled = {}
package.preload["logger"] = function() return { warn = function() end, info = function() end, dbg = function() end } end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, s, fn) scheduled[#scheduled + 1] = { s = s, fn = fn } end }
end
local function tick()
    local list = scheduled
    scheduled = {}
    for _, s in ipairs(list) do s.fn() end
    return #list
end

local Background = require("pageframe_background")

-- A pretend fork: the "child" runs when told (or straight away), writing into a fake pipe.
-- o = { fail_fork, defer, silent (child exits without writing), hang (never finishes) }
local function fakeUtil(o)
    o = o or {}
    local u = { killed = 0, reaped = 0, forks = 0 }
    local pipe, child
    function u.runInSubProcess(func, with_pipe)
        assert(with_pipe == true, "results come through a pipe")
        if o.fail_fork then return false, "fork failed" end
        u.forks = u.forks + 1
        pipe = { data = nil, closed = false }
        child = { finished = false }
        child.run = function()
            if not o.silent then func(1234, pipe) end
            if not o.hang then child.finished = true end
        end
        if not o.defer then child.run() end
        return 1234, pipe
    end
    function u.writeToFD(fd, data, close)
        fd.data, fd.closed = data, close
        return true
    end
    function u.getNonBlockingReadSize(fd) return fd.data and #fd.data or 0 end
    function u.readAllFromFD(fd)
        local d = fd.data or ""
        fd.data = nil
        return d
    end
    function u.isSubProcessDone(_, wait)
        if child.finished then u.reaped = u.reaped + 1 end
        return child.finished or (wait and true) or false
    end
    function u.terminateSubProcess() u.killed = u.killed + 1; child.finished = true end
    u.child = function() return child end
    return u
end

local function reset(u)
    scheduled = {}
    Background._util, Background.disabled = u, false
end

test("background: the task's values come back on a later check, not at once", function()
    local u = fakeUtil()
    reset(u)
    local got
    eq(Background.run(function() return { a = 1, list = { "x", "y" } }, "two", 3 end, function(...) got = { ... } end), "background")
    eq(got, nil) -- nothing yet: the parent only looks on its next check
    tick()
    eq(got, { true, { a = 1, list = { "x", "y" } }, "two", 3 })
    eq(u.forks, 1)
end)

test("background: nil values in the middle survive the trip", function()
    reset(fakeUtil())
    local got
    Background.run(function() return nil, "network" end, function(...) got = { n = select("#", ...), ... } end)
    tick()
    eq({ got.n, got[1], got[2], got[3] }, { 3, true, nil, "network" })
end)

test("background: an error in the task comes back as false and the message", function()
    reset(fakeUtil())
    local ok, err
    Background.run(function() error("boom", 0) end, function(a, b) ok, err = a, b end)
    tick()
    eq({ ok, err }, { false, "boom" })
end)

test("background: a slow child is checked again and again, with growing gaps up to a second", function()
    local u = fakeUtil{ defer = true }
    reset(u)
    local got
    Background.run(function() return "late" end, function(_, v) got = v end)
    local gaps = {}
    for _ = 1, 20 do
        gaps[#gaps + 1] = scheduled[1].s
        tick()
    end
    eq({ gaps[1], gaps[8], gaps[9], gaps[17], gaps[20] }, { 0.25, 0.25, 0.5, 1, 1 })
    eq(got, nil)
    u.child().run()
    tick()
    eq(got, "late")
end)

test("background: a child that dies without answering switches to inline, redoing the job here", function()
    local u = fakeUtil{ silent = true }
    reset(u)
    local runs, got = 0, nil
    Background.run(function() runs = runs + 1; return "done" end, function(_, v) got = v end)
    tick()
    eq({ got, runs, Background.broken }, { "done", 1, true }) -- (the silent child never ran it)
    -- from now on, inline straight away
    eq(Background.run(function() return 2 end, function(_, v) got = v end), "inline")
    eq({ got, u.forks }, { 2, 1 })
    Background.broken = false
end)

test("background: a job that mustn't repeat is reported as a crash instead", function()
    reset(fakeUtil{ silent = true })
    local runs, ok, err = 0, nil, nil
    Background.run(function() runs = runs + 1 end, function(a, b) ok, err = a, b end, { once = true })
    tick()
    eq({ ok, err, runs, Background.broken }, { false, "crash", 0, false })
end)

test("background: a child that takes too long is stopped, reported, and collected later", function()
    local u = fakeUtil{ defer = true, hang = true }
    reset(u)
    local ok, err
    Background.run(function() return 1 end, function(a, b) ok, err = a, b end, { timeout = 0 })
    tick()
    eq({ ok, err, u.killed }, { false, "timeout", 1 })
    eq(scheduled[1] and scheduled[1].s, Background.REAP_EVERY)
    tick() -- the reaper finds it gone
    eq(#scheduled, 0)
end)

test("background: no subprocess support, a failed fork, or disabled → runs here, as before", function()
    for _, setup in ipairs({
        function() reset({}) end,                                  -- no runInSubProcess
        function() reset(fakeUtil{ fail_fork = true }) end,
        function() reset(fakeUtil()); Background.disabled = true end,
    }) do
        setup()
        local got
        eq(Background.run(function() return "here" end, function(_, v) got = v end), "inline")
        eq({ got, #scheduled }, { "here", 0 })
    end
    reset(nil)
end)

test("background: results that can't be encoded are reported, not lost silently", function()
    reset(fakeUtil())
    local ok, err
    Background.run(function() return function() end end, function(a, b) ok, err = a, b end)
    tick()
    eq({ ok, err }, { false, "encode" })
    reset(nil)
end)

H.done()
