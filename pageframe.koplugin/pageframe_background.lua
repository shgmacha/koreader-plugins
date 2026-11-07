--[[--
Runs slow work (Page Frame's update check against GitHub) in a child process,
so KOReader keeps drawing and answering taps meanwhile.

The same way KOReader's own thumbnailer and Trapper do it: fork with a pipe
(ffi/util.runInSubProcess), the child runs the task and writes its results,
encoded with LuaJIT's string.buffer, and the parent checks on it from the
UIManager loop without ever blocking. Tasks return plain values (tables,
strings, numbers, booleans); a child writes no state of its own, the parent
applies what comes back.

Without the subprocess API (or if the fork fails) the task simply runs inline,
which still works, only without the background. Some systems can't do everything in a
forked process (macOS: the first TLS connection must not happen in a child), so a
child that dies without answering switches background jobs off for the rest of
the run, and that job is redone inline (unless opts.once: it must not repeat).
--]]

local logger = require("logger")

local Background = {
    NIL = "\0nil",       -- marks a removed field in results (nil can't travel in a table)
    TIMEOUT = 300,       -- seconds before a child is stopped
    POLL_FIRST = 0.25,   -- first check, doubling every 8 checks…
    POLL_MAX = 1,        -- …up to once a second
    REAP_EVERY = 5,      -- a stopped child is collected in the background
    disabled = false,    -- true: always inline (as before)
    broken = false,      -- a child died without answering: inline for the rest of this run
    _util = nil,         -- tests: a stand-in for ffi/util
}

local function pack(...)
    return { n = select("#", ...), ... }
end

local function subprocessUtil()
    if Background._util then return Background._util end
    local ok, util = pcall(require, "ffi/util")
    return ok and util or nil
end

local function inline(task, on_done)
    local r = pack(pcall(task))
    on_done(unpack(r, 1, r.n))
    return "inline"
end

--- Runs task() in a child process and calls on_done(ok, ...) in this one with what it returned
--- (ok false and an error: the task's error, "crash" or "timeout").
--- opts.timeout: seconds (default Background.TIMEOUT); opts.once: never redo the task inline.
--- Returns "background", or "inline" when on_done has already been called.
function Background.run(task, on_done, opts)
    opts = opts or {}
    local util = subprocessUtil()
    local has_buffer, buffer = pcall(require, "string.buffer")
    if Background.disabled or Background.broken or not (util and util.runInSubProcess and has_buffer) then
        return inline(task, on_done)
    end

    local pid, fd = util.runInSubProcess(function(_pid, write_fd)
        local r = pack(pcall(task))
        local ok, data = pcall(buffer.encode, r)
        if not ok then data = buffer.encode(pack(false, "encode")) end
        util.writeToFD(write_fd, data, true)
    end, true)
    if not pid then
        logger.warn("PageFrame: couldn't start a background job, running it here:", fd)
        return inline(task, on_done)
    end

    local UIManager = require("ui/uimanager")
    local started, interval, polls = os.time(), Background.POLL_FIRST, 0

    -- A stopped child is collected later, reading what it may still be writing so it can exit.
    local function reap()
        if fd then
            local n = util.getNonBlockingReadSize(fd)
            if n and n > 0 then
                util.readAllFromFD(fd)
                fd = nil
            end
        end
        if util.isSubProcessDone(pid) then
            if fd then util.readAllFromFD(fd) end
            return
        end
        UIManager:scheduleIn(Background.REAP_EVERY, reap)
    end

    local function poll()
        polls = polls + 1
        local done = util.isSubProcessDone(pid)
        local waiting = util.getNonBlockingReadSize(fd)
        if done or (waiting and waiting > 0) then
            -- The child closes the pipe right after writing, so this read doesn't wait long.
            local data = util.readAllFromFD(fd) or ""
            if not done then util.isSubProcessDone(pid, true) end
            local ok, r = pcall(buffer.decode, data)
            if data ~= "" and ok and type(r) == "table" and r.n then
                return on_done(unpack(r, 1, r.n))
            end
            logger.warn("PageFrame: a background job ended without an answer")
            if opts.once then return on_done(false, "crash") end
            logger.warn("PageFrame: background jobs don't work here; running them in KOReader itself from now on")
            Background.broken = true
            return inline(task, on_done)
        end
        if os.time() - started >= (opts.timeout or Background.TIMEOUT) then
            logger.warn("PageFrame: a background job took too long and was stopped")
            util.terminateSubProcess(pid)
            UIManager:scheduleIn(Background.REAP_EVERY, reap)
            return on_done(false, "timeout")
        end
        if polls % 8 == 0 then interval = math.min(interval * 2, Background.POLL_MAX) end
        UIManager:scheduleIn(interval, poll)
    end
    UIManager:scheduleIn(interval, poll)
    return "background"
end

return Background
