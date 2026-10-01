--[[--
Runs a sync: the plan for each book, then the yearly-goal link.

I/O is injected (api, books, goal accessors) so this runs under plain LuaJIT.
A failed action leaves that book's state as it was, so the next sync simply
tries again; that is the whole retry mechanism (no queue), as in iCloud Sync.
--]]

local Plan = require("blossomreads_plan")

local Engine = {}

-- Errors that make the rest of the run pointless.
local STOP = { signin = true, network = true, blocked = true }

-- ctx = {
--   api,                         -- blossomreads_api instance
--   books,                       -- map file -> entry (mutated in place)
--   items = { { file, now = { pct, status }, shelves = { collection shelf slugs } } },
--   opts = { complete_at_99 },
--   goal = { get = fn -> n|nil, set = fn(n), synced = n|nil } or nil,
--   time,
-- }
-- Returns { time, books, pushed, shelved, failed, changed, error, goal, synced, challenge }.
function Engine.run(ctx)
    local s = { time = ctx.time or os.time(), books = 0, pushed = 0, shelved = 0, failed = 0, changed = false }
    for _, item in ipairs(ctx.items or {}) do
        local entry = ctx.books[item.file]
        if entry and entry.gid then
            local before = s.pushed + s.shelved
            local opts = { complete_at_99 = (ctx.opts or {}).complete_at_99, collection_shelves = item.shelves }
            for _, action in ipairs(Plan.planBook(item.now, entry, opts)) do
                local ok, err
                if action.type == "shelf" and action.custom then
                    -- A collection's own shelf, alongside the reading status.
                    ok, err = ctx.api:setShelf(entry.gid, action.shelf)
                    if ok then
                        entry.collections_sent = entry.collections_sent or {}
                        table.insert(entry.collections_sent, action.shelf)
                        s.shelved = s.shelved + 1
                    end
                elseif action.type == "unshelf" then
                    ok, err = ctx.api:unshelf(entry.gid, action.shelf)
                    if ok then
                        for i = #(entry.collections_sent or {}), 1, -1 do
                            if entry.collections_sent[i] == action.shelf then table.remove(entry.collections_sent, i) end
                        end
                        if #entry.collections_sent == 0 then entry.collections_sent = nil end
                        s.shelved = s.shelved + 1
                    end
                elseif action.type == "shelf" then
                    ok, err = ctx.api:setShelf(entry.gid, action.shelf)
                    if ok then
                        entry.pushed_shelf = action.shelf
                        if action.shelf == Plan.READ then
                            entry.pushed_pct, entry.pinned_shelf = 100, nil
                        end
                        s.shelved = s.shelved + 1
                    end
                else
                    ok, err = ctx.api:progress(entry.gid, action.pct)
                    if ok then
                        entry.pushed_pct = action.pct
                        s.pushed = s.pushed + 1
                    end
                end
                if ok then
                    entry.synced_at = s.time
                    s.changed = true
                else
                    s.failed = s.failed + 1
                    if STOP[err] then s.error = err; return s end
                    break -- keep this book's order; the next sync retries it
                end
            end
            if s.pushed + s.shelved > before then s.books = s.books + 1 end
        end
    end
    if ctx.goal then Engine.syncGoal(ctx.api, ctx.goal, s) end
    return s
end

function Engine.syncGoal(api, goal, s)
    local ch, err = api:challenge()
    if not ch then
        if STOP[err] then s.error = err end
        return
    end
    s.challenge = ch
    local d = Plan.decideGoal(goal.get(), ch.goal, goal.synced)
    if d.action == "push" then
        local ok, perr = api:setGoal(d.value)
        if not ok then
            s.failed = s.failed + 1
            if STOP[perr] then s.error = perr end
            return
        end
        ch.goal = d.value
        s.synced, s.goal = d.value, d
    elseif d.action == "pull" then
        goal.set(d.value)
        s.synced, s.goal = d.synced, d
    elseif d.action == "adopt" then
        s.synced = d.synced
    end
    if s.goal then s.changed = true end
end

return Engine
