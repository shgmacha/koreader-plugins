--[[--
Read dates and rereads, through Goodreads' own review page.

Goodreads keeps every read of a book as a "reading session" (started / finished
dates). Shelving a book as Read creates one with no dates. The review page
(/review/edit/<id>) lists your sessions across all editions of the work, and
saves them with a Next.js server action, "submitReviewFormAction". Its id
changes with each Goodreads release, so it's found in the page's scripts and
remembered until it changes.

Safety: dates are only written to editions without a review (so a review can
never be overwritten), private notes are sent back as they were, nothing is
posted to your update feed or blog, and every save is checked by reloading the
page.
--]]

local Http = require("blossomreads_http")

local Review = {}

local BASE = "https://www.goodreads.com"
local ROUTE = "/review/edit/[id]"
local MAX_CHUNKS = 8

--------------------------------------------------------------------------------
-- Reading the page
--------------------------------------------------------------------------------

-- The string literals of every self.__next_f.push([1,"…"]) on the page.
local function flightStrings(html)
    local out, pos = {}, 1
    local marker = 'self.__next_f.push([1,"'
    while true do
        local s, e = html:find(marker, pos, true)
        if not s then break end
        local i = e + 1
        while i <= #html do
            local c = html:sub(i, i)
            if c == "\\" then
                i = i + 2
            elseif c == '"' then
                break
            else
                i = i + 1
            end
        end
        out[#out + 1] = Http.json(html:sub(e, i)) or ""
        pos = i + 1
    end
    return out
end

-- The JSON value (object, array or string) that starts at position i.
local function jsonAt(s, i)
    local first = s:sub(i, i)
    local depth, j, in_str = 0, i, first == '"'
    if in_str then j = i + 1 end
    while j <= #s do
        local c = s:sub(j, j)
        if in_str then
            if c == "\\" then
                j = j + 1
            elseif c == '"' then
                in_str = false
                if first == '"' then return Http.json(s:sub(i, j)) end
            end
        elseif c == '"' then
            in_str = true
        elseif c == "[" or c == "{" then
            depth = depth + 1
        elseif c == "]" or c == "}" then
            depth = depth - 1
            if depth == 0 then return Http.json(s:sub(i, j)) end
        end
        j = j + 1
    end
end

local function valueOf(payload, key)
    local _, e = payload:find('"' .. key .. '":', 1, true)
    if not e then return nil end
    return jsonAt(payload, e + 1)
end

local function dateKey(d)
    if type(d) ~= "table" or not d.year then return nil end
    return d.year * 10000 + (d.month or 0) * 100 + (d.day or 0)
end
Review.dateKey = dateKey

-- "2026-09-02" -> { year = 2026, month = 9, day = 2 }
function Review.date(text)
    local y, m, d = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

-- The parts of the review page Blossom Reads needs.
function Review.parse(html, gid)
    gid = tostring(gid)
    local payload = table.concat(flightStrings(html or ""))
    local page = {
        gid = gid,
        book_id = payload:match('"id":"(kca://book/[^"]+)","legacyId":' .. gid .. "[,}]"),
        has_review = not payload:find('"review":null,"draftConfig"', 1, true),
        notes = valueOf(payload, "initialPrivateNotes") or "",
        owned = payload:match('"isAlreadyOwned":(%a+)') == "true",
        shelvings = valueOf(payload, "viewerShelvings") or {},
        sessions = valueOf(payload, "initialReadingSessions") or {},
        scripts = {},
    }
    -- Dates in the form's sessions point ("$…") at the same sessions under viewerShelvings.
    local real = {}
    for _, shelving in ipairs(page.shelvings) do
        for _, s in ipairs(shelving.readingSessions or {}) do real[s.id] = s end
    end
    for _, s in ipairs(page.sessions) do
        for _, k in ipairs({ "startedDate", "endedDate" }) do
            if type(s[k]) == "string" then s[k] = real[s.id] and real[s.id][k] or nil end
        end
    end
    for src in (html or ""):gmatch('src="(/_next/static/chunks/[^"]+%.js)"') do
        page.scripts[#page.scripts + 1] = src
    end
    return page
end

function Review.load(http, gid)
    local r = http:get(BASE .. "/review/edit/" .. tostring(gid))
    if r.err then return nil, r.err end
    local page = Review.parse(r.body, gid)
    if not page.book_id then return nil, "unexpected" end
    return page
end

-- Another edition of this book that's already on one of your shelves (nil if none).
function Review.ownEdition(page)
    for _, shelving in ipairs(page.shelvings or {}) do
        local legacy = shelving.book and shelving.book.legacyId
        if legacy and tostring(legacy) ~= page.gid and shelving.shelf and shelving.shelf.name then
            return tostring(legacy), shelving.shelf.name
        end
    end
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

local SKIP = { "polyfills", "webpack", "main%-app", "not%-found", "framework", "/layout%-" }

-- The current id of the save action, from the page's own scripts (route chunks are last).
-- cache = { id, chunk } is kept between syncs.
function Review.actionId(http, page, cache)
    local candidates = {}
    for i = #page.scripts, 1, -1 do
        local src, skip = page.scripts[i], false
        for _, p in ipairs(SKIP) do
            if src:find(p) then skip = true end
        end
        if not skip then candidates[#candidates + 1] = src end
    end
    if cache.id then
        for _, src in ipairs(candidates) do
            if src == cache.chunk then return cache.id end
        end
    end
    for i = 1, math.min(#candidates, MAX_CHUNKS) do
        local r = http:get(BASE .. candidates[i])
        local id = not r.err and r.body and
            r.body:match('createServerReference%)%("(%x+)",[^)]-"submitReviewFormAction"%)')
        if id then
            cache.id, cache.chunk = id, candidates[i]
            return id
        end
    end
    return nil, "unexpected"
end

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

-- Every session written back in full (missing dates become explicit nulls).
local function forJson(sessions)
    local out = Http.array()
    for i, s in ipairs(sessions) do
        local c = copy(s)
        if c.startedDate == nil then c.startedDate = Http.null end
        if c.endedDate == nil then c.endedDate = Http.null end
        out[i] = c
    end
    return out
end

local countEnding

local function hasRead(sessions, key)
    for _, s in ipairs(sessions) do
        if s.state == "COMPLETED" and dateKey(s.endedDate) == key then return true end
    end
    return false
end

-- Record a read: read = { ended = date, started = date|nil }.
-- mode "first": the book's first read. Fills in the undated session Goodreads made when it was
--   shelved as Read; if any edition already has a finish date, that's respected.
-- mode "reread": adds another read, unless that day's read is already there.
-- Returns ok, what ("saved" | "already" | "dated") or nil, error
-- (error "has_review" means it was skipped so a review is never touched).
function Review.addRead(http, gid, read, mode, cache)
    local page, err = Review.load(http, gid)
    if not page then return nil, err end
    local want = dateKey(read.ended)
    if not want then return nil, "unexpected" end
    if hasRead(page.sessions, want) then return true, "already" end
    local sessions, target = copy(page.sessions), nil
    if mode ~= "reread" then
        for _, s in ipairs(sessions) do
            if s.state == "COMPLETED" and dateKey(s.endedDate) then return true, "dated" end
        end
        for _, s in ipairs(sessions) do
            if s.state == "COMPLETED" and s.bookId == page.book_id then target = s end
        end
    end
    if page.has_review then return nil, "has_review" end
    if target then
        target.endedDate, target.startedDate = read.ended, read.started
    else
        sessions[#sessions + 1] = {
            __typename = "ReadingSession", id = "new-" .. tostring(os.time() * 1000),
            bookId = page.book_id, state = "COMPLETED", startedDate = read.started, endedDate = read.ended,
        }
    end
    local ok, what = Review.save(http, page, sessions, cache, target and target.id)
    return ok, what
end

function countEnding(sessions, key)
    local n = 0
    for _, s in ipairs(sessions or {}) do
        if s.state == "COMPLETED" and dateKey(s.endedDate) == key then n = n + 1 end
    end
    return n
end

-- Save the page's sessions as given, then check on the reloaded page that it took:
-- the session `target_id` now has the wanted dates, or (new read) one more read ends that day.
function Review.save(http, page, sessions, cache, target_id)
    if page.has_review then return nil, "has_review" end
    local id, aerr = Review.actionId(http, page, cache)
    if not id then return nil, aerr end
    local body = Http.jsonEncode({ {
        bookId = page.book_id,
        reviewText = "",
        spoilerStatus = false,
        isOwnedEdition = page.owned,
        privateNotes = page.notes,
        postToBlog = false,
        addToUpdateFeed = false,
        readingSessions = forJson(sessions),
        initialReadingSessions = forJson(page.sessions),
    }, ROUTE })
    local r = http:request("POST", BASE .. "/review/edit/" .. page.gid, {
        body = body,
        headers = {
            ["Next-Action"] = id,
            ["Accept"] = "text/x-component",
            ["Content-Type"] = "text/plain;charset=UTF-8",
        },
    })
    if r.err then return nil, r.err end
    -- Trust only what Goodreads shows afterwards.
    local after = Review.load(http, page.gid)
    local wanted
    for _, s in ipairs(sessions) do
        if (target_id and s.id == target_id) or (not target_id and tostring(s.id):find("^new%-")) then wanted = s end
    end
    local took = false
    if after and wanted then
        if target_id then
            for _, s in ipairs(after.sessions) do
                if s.id == target_id and dateKey(s.endedDate) == dateKey(wanted.endedDate)
                    and dateKey(s.startedDate) == dateKey(wanted.startedDate) then took = true end
            end
        else
            local key = dateKey(wanted.endedDate)
            took = countEnding(after.sessions, key) > countEnding(page.sessions, key)
        end
    end
    if took then return true, "saved", after end
    cache.id, cache.chunk = nil, nil -- the action may have changed; look it up again next time
    return nil, "unexpected", after
end

Review.copy = copy

return Review
