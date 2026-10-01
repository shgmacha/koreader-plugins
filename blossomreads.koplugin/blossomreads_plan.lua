--[[--
Pure sync decisions (no I/O), like iCloud Sync's planner.

planBook compares what KOReader knows about a book with what was last pushed
to Goodreads. decideGoal is a three-way merge of Blossom's yearly goal,
the Goodreads challenge goal and the value they last agreed on.
--]]

local Plan = {}

Plan.READING, Plan.READ = "currently-reading", "read"

-- now: { pct = 0..100 (whole) or nil, status = "complete" | "abandoned" | other }
-- saved: { pushed_pct, pushed_shelf, pinned_shelf }
-- opts: { complete_at_99 }
-- Returns a list of { type = "shelf", shelf } / { type = "progress", pct }.
function Plan.planBook(now, saved, opts)
    now, saved, opts = now or {}, saved or {}, opts or {}
    local actions = {}
    if now.status == "abandoned" then return actions end
    local pct = tonumber(now.pct)

    local finished = now.status == "complete" or (opts.complete_at_99 and pct and pct >= 99)
    if finished then
        -- Finishing is an explicit signal, so it applies even over a pinned shelf.
        if saved.pushed_shelf ~= Plan.READ then
            actions[#actions + 1] = { type = "shelf", shelf = Plan.READ }
        end
        return actions -- Goodreads records 100% itself when a book is marked Read
    end
    if saved.pushed_shelf == Plan.READ then return actions end

    if pct and pct > 0 and not saved.pinned_shelf and saved.pushed_shelf ~= Plan.READING then
        actions[#actions + 1] = { type = "shelf", shelf = Plan.READING }
    end
    -- Progress only ever moves forward.
    if pct and pct > 0 and pct > (tonumber(saved.pushed_pct) or 0) then
        actions[#actions + 1] = { type = "progress", pct = math.min(100, math.floor(pct)) }
    end
    return actions
end

function Plan.clampGoal(n)
    n = math.floor(tonumber(n) or 0)
    if n < 1 then return nil end
    return math.min(n, 365) -- Blossom's limit
end

-- blossom: Blossom's goal (nil = never set); goodreads: challenge goal
-- (0 = no challenge this year, nil = couldn't fetch); synced: last agreed goal.
-- Returns { action = "skip" | "adopt" | "push" | "pull", value }.
function Plan.decideGoal(blossom, goodreads, synced)
    local B = Plan.clampGoal(blossom)
    local G = tonumber(goodreads)
    if G == nil then return { action = "skip" } end
    if G < 1 then
        if B then return { action = "push", value = B } end
        return { action = "skip" }
    end
    if not B then return { action = "pull", value = Plan.clampGoal(G), synced = G } end
    -- Blossom can't hold more than 365, so compare against what it can hold.
    if B == Plan.clampGoal(G) then return { action = "adopt", synced = G } end
    local S = Plan.clampGoal(synced)
    if S and B ~= S and G == synced then return { action = "push", value = B } end
    -- Goodreads changed, both changed, or first sync: Goodreads wins.
    return { action = "pull", value = Plan.clampGoal(G), synced = G }
end

return Plan
