--[[--
Pure sync decisions (no I/O), like iCloud Sync's planner.

planBook compares what KOReader knows about a book (progress, status, the
collections it's in) with what was last sent to Goodreads. decideGoal is a
three-way merge of Blossom's yearly goal, the Goodreads challenge goal and the
value they last agreed on.
--]]

local Plan = {}

Plan.READING, Plan.READ = "currently-reading", "read"

-- Goodreads keeps exactly one of these per book; higher wins between collections.
local STATUS_RANK = { ["to-read"] = 1, ["did-not-finish"] = 2, ["currently-reading"] = 3, ["read"] = 4 }

function Plan.isStatus(slug)
    return STATUS_RANK[slug] ~= nil
end

-- "Cozy Autumn!" -> "cozy-autumn"
function Plan.slug(name)
    return ((name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

local NAMED = {
    ["to be read"] = "to-read", ["tbr"] = "to-read", ["want to read"] = "to-read", ["to read"] = "to-read",
    ["currently reading"] = "currently-reading", ["reading"] = "currently-reading",
    ["read"] = "read", ["finished"] = "read", ["done"] = "read",
    ["dnf"] = "did-not-finish", ["did not finish"] = "did-not-finish",
}

-- The Goodreads shelf for a KOReader collection, or nil when it isn't synced.
-- override: nil / "auto" (by name), "off", or a shelf slug.
function Plan.collectionShelf(name, override)
    if override == "off" then return nil end
    if override and override ~= "auto" then return override end
    local key = (name or ""):lower():gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", "")
    local slug = NAMED[key] or Plan.slug(name)
    return slug ~= "" and slug or nil
end

local function has(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

-- Reading status first: progress and finishing always beat a collection.
local function statusActions(actions, now, saved, opts, shelves)
    local pct = tonumber(now.pct)
    local finished = now.status == "complete" or (opts.complete_at_99 and pct and pct >= 99)
    if finished then
        -- Finishing is an explicit signal, so it applies even over a pinned shelf.
        if saved.pushed_shelf ~= Plan.READ then
            actions[#actions + 1] = { type = "shelf", shelf = Plan.READ }
        end
        return -- Goodreads records 100% itself when a book is marked Read
    end
    if saved.pushed_shelf == Plan.READ then return end

    if pct and pct > 0 then
        if not saved.pinned_shelf and saved.pushed_shelf ~= Plan.READING then
            actions[#actions + 1] = { type = "shelf", shelf = Plan.READING }
        end
        -- Progress only ever moves forward.
        if pct > (tonumber(saved.pushed_pct) or 0) then
            actions[#actions + 1] = { type = "progress", pct = math.min(100, math.floor(pct)) }
        end
        return
    end

    -- Not started: a collection like "To Be Read" or "DNF" may set the status.
    if saved.pinned_shelf or saved.pushed_shelf == Plan.READING then return end
    local best
    for _, slug in ipairs(shelves) do
        if STATUS_RANK[slug] and (not best or STATUS_RANK[slug] > STATUS_RANK[best]) then best = slug end
    end
    if best and best ~= saved.pushed_shelf then
        actions[#actions + 1] = { type = "shelf", shelf = best }
    end
end

-- Custom shelves mirror the collections: add new ones, remove ones the book left
-- (only shelves Blossom Reads added itself).
local function customActions(actions, saved, shelves)
    for _, slug in ipairs(shelves) do
        if not STATUS_RANK[slug] and not has(saved.collections_sent, slug) then
            actions[#actions + 1] = { type = "shelf", shelf = slug, custom = true }
        end
    end
    for _, slug in ipairs(saved.collections_sent or {}) do
        if not has(shelves, slug) then
            actions[#actions + 1] = { type = "unshelf", shelf = slug }
        end
    end
end

-- now: { pct = 0..100 (whole) or nil, status = "complete" | "abandoned" | other }
-- saved: { pushed_pct, pushed_shelf, pinned_shelf, collections_sent }
-- opts: { complete_at_99, collection_shelves = { slug, … } }
-- Returns a list of { type = "shelf", shelf[, custom] } / { type = "unshelf", shelf } /
-- { type = "progress", pct }.
function Plan.planBook(now, saved, opts)
    now, saved, opts = now or {}, saved or {}, opts or {}
    local shelves = opts.collection_shelves or {}
    local actions = {}
    if now.status ~= "abandoned" then statusActions(actions, now, saved, opts, shelves) end
    customActions(actions, saved, shelves)
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
