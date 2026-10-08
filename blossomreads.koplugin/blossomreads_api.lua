--[[--
The Goodreads calls Blossom Reads needs, on top of the signed-in cookie jar.

Every call returns value, err. err is one of blossomreads_http's codes, or
"unexpected" when a page couldn't be understood. Shelves are Goodreads slugs:
"to-read", "currently-reading", "read", "did-not-finish" or a custom name.
--]]

local Http = require("blossomreads_http")

local Api = {}
Api.__index = Api

local BASE = "https://www.goodreads.com"
local CSRF_TTL = 120
local DEFAULT_SHELVES = { ["to-read"] = true, ["currently-reading"] = true, ["read"] = true, ["did-not-finish"] = true }
Api.DEFAULT_SHELVES = DEFAULT_SHELVES

function Api.new(opts)
    opts = opts or {}
    return setmetatable({
        http = Http.new{ cookies = opts.cookies, transport = opts.transport },
        user_id = opts.user_id,
    }, Api)
end

function Api:cookies()
    return self.http.cookies
end

local function unescape(s)
    if not s then return nil end
    s = s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&nbsp;", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Goodreads rotates its form token; reuse one for a couple of minutes per run.
function Api:csrf()
    if self._csrf and os.time() - self._csrf_at < CSRF_TTL then return self._csrf end
    local r = self.http:get(BASE .. "/review/list")
    if r.err then return nil, r.err end
    local body = r.body or ""
    local token = body:match('<meta%s+[^>]-name="csrf%-token"%s+[^>]-content="([^"]+)"')
        or body:match('<meta%s+[^>]-content="([^"]+)"%s+[^>]-name="csrf%-token"')
    if not token then return nil, "unexpected" end
    self.user_id = body:match("/user/show/(%d+)") or self.user_id
    self._csrf, self._csrf_at = token, os.time()
    return token
end

local function writeOpts(token)
    return { csrf = token, xhr = true }
end

--------------------------------------------------------------------------------
-- Books
--------------------------------------------------------------------------------

function Api:search(query)
    if (query or "") == "" then return {} end
    local r = self.http:get(BASE .. "/book/auto_complete?format=json&q=" .. Http.urlencode(query), { xhr = true })
    if r.err then return nil, r.err end
    local list = Http.json(r.body)
    if type(list) ~= "table" then return nil, "unexpected" end
    local out = {}
    for _, item in ipairs(list) do
        if type(item) == "table" and item.bookId then
            out[#out + 1] = {
                gid = tostring(item.bookId),
                title = unescape(item.bookTitleBare or item.title),
                full_title = unescape(item.title), -- with the series, e.g. "Title (Series, #4)"
                author = type(item.author) == "table" and unescape(item.author.name) or nil,
                cover = item.imageUrl,
                pages = tonumber(item.numPages),
            }
        end
    end
    return out
end

function Api:book(gid)
    local r = self.http:get(BASE .. "/book/show/" .. tostring(gid))
    if r.err then return nil, r.err end
    local block = (r.body or ""):match('<script type="application/ld%+json">(.-)</script>')
    local ld = block and Http.json(block)
    if type(ld) ~= "table" then return nil, "unexpected" end
    local a = type(ld.author) == "table" and (ld.author[1] or ld.author) or {}
    return {
        gid = tostring(gid),
        title = unescape(ld.name),
        author = unescape(a.name),
        cover = ld.image,
        pages = tonumber(ld.numberOfPages),
        isbn = ld.isbn,
        avg_rating = type(ld.aggregateRating) == "table" and tonumber(ld.aggregateRating.ratingValue) or nil,
    }
end

--------------------------------------------------------------------------------
-- Shelves
--------------------------------------------------------------------------------

-- Your shelves with counts: { { slug, custom, count } }.
function Api:shelves()
    local r = self.http:get(BASE .. "/review/list")
    if r.err then return nil, r.err end
    local body = r.body or ""
    local names = {}
    local arr = body:match("new%s+ShelfChooser%s*%(.-(%b[])")
    for name in (arr or ""):gmatch('"([^"]+)"') do names[#names + 1] = name end
    -- Goodreads links status shelves (custom ones too, like "paused") with shelf=, tags with tag=.
    local counts, params = {}, {}
    for kind, name, n in body:gmatch("[%?&](%a+)=([%w%-_%.]+)['\"]?[^>]*>[^<]-%((%d+)%)") do
        if kind == "shelf" or kind == "tag" then counts[name], params[name] = tonumber(n), kind end
    end
    if #names == 0 then
        for name in pairs(counts) do names[#names + 1] = name end
        table.sort(names)
    end
    local out, seen = {}, {}
    for _, name in ipairs(names) do
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = { slug = name, custom = not DEFAULT_SHELVES[name], count = counts[name],
                param = params[name] or (DEFAULT_SHELVES[name] and "shelf" or "tag") }
        end
    end
    if #out == 0 then return nil, "unexpected" end
    return out
end

-- One page (up to 30) of a shelf: books, has_more. param: "shelf" or "tag" (from shelves()).
function Api:shelfBooks(slug, page, param)
    param = param or (DEFAULT_SHELVES[slug] and "shelf" or "tag")
    param = param .. "=" .. Http.urlencode(slug)
    local r = self.http:get(string.format("%s/review/list?%s&per_page=30&page=%d&view=table", BASE, param, page or 1))
    if r.err then return nil, r.err end
    local body = r.body or ""
    local books, seen = {}, {}
    for row in body:gmatch('<tr[^>]*class="[^"]*bookalike[^"]*review[^"]*"(.-)</tr>') do
        local title, gid = row:match('<a[^>]-title="([^"]+)"[^>]-href="[^"]*/book/show/(%d+)')
        if not gid then gid, title = row:match('href="[^"]*/book/show/(%d+)[^"]*"[^>]-title="([^"]+)"') end
        if gid and not seen[gid] then
            seen[gid] = true
            local cover = row:match('id="cover_[^"]*"[^>]-src="([^"]+)"') or row:match('<img[^>]-src="([^"]+)"')
            local rating = tonumber(row:match('data%-rating="([%d%.]+)"'))
            books[#books + 1] = {
                gid = gid,
                title = unescape(title),
                author = unescape(row:match('class="field author"[^>]*>.-<a[^>]*>([^<]-)</a>')),
                cover = cover and unescape(cover) or nil,
                rating = rating and rating > 0 and math.floor(rating + 0.5) or nil,
            }
        end
    end
    return books, body:find('rel="next"', 1, true) ~= nil
end

local function shelfPost(self, gid, slug, action)
    local token, err = self:csrf()
    if not token then return nil, err end
    local r = self.http:post(BASE .. "/shelf/add_to_shelf",
        { book_id = tostring(gid), name = slug, a = action, authenticity_token = token }, writeOpts(token))
    if r.err then return nil, r.err end
    return true
end

-- Put a book on a shelf (Goodreads creates a custom shelf the first time it's used).
function Api:setShelf(gid, slug)
    return shelfPost(self, gid, slug, "")
end

-- Take a book off a custom shelf.
function Api:unshelf(gid, slug)
    return shelfPost(self, gid, slug, "remove")
end

-- Reading progress as a whole percent (1–100).
function Api:progress(gid, pct)
    pct = math.max(1, math.min(100, math.floor((tonumber(pct) or 0) + 0.5)))
    local token, err = self:csrf()
    if not token then return nil, err end
    local fields = {
        ["user_status[book_id]"] = tostring(gid),
        ["user_status[percent]"] = tostring(pct),
        ["user_status[body]"] = "",
        authenticity_token = token,
    }
    local r = self.http:post(BASE .. "/user_status.json", fields, writeOpts(token))
    if r.err == Http.ERR.NOT_FOUND then
        r = self.http:post(BASE .. "/user_status", fields, writeOpts(token))
    end
    if r.err then return nil, r.err end
    return pct
end

function Api:rate(gid, stars)
    stars = math.floor(tonumber(stars) or 0)
    if stars < 1 or stars > 5 then return nil, "unexpected" end
    local token, err = self:csrf()
    if not token then return nil, err end
    local r = self.http:post(string.format(
        "%s/review/rate/%s?no_lightbox=true&queue=false&stars_click=true&rating=%d", BASE, tostring(gid), stars),
        "", writeOpts(token))
    if r.err then return nil, r.err end
    return stars
end

--------------------------------------------------------------------------------
-- Read dates (reading sessions, through the review page)
--------------------------------------------------------------------------------

-- read = { ended = {year,month,day}, started = … }, mode "first" | "reread".
-- self.review_cache keeps the review page's save-action id between calls.
function Api:addRead(gid, read, mode)
    self.review_cache = self.review_cache or {}
    return require("blossomreads_review").addRead(self.http, gid, read, mode, self.review_cache)
end

--------------------------------------------------------------------------------
-- Reading challenge
--------------------------------------------------------------------------------

-- { goal (0 = no challenge yet), read, days_left }
function Api:challenge()
    local r = self.http:get(BASE .. "/readingchallenges/goals/data", { xhr = true })
    if r.err then return nil, r.err end
    local d = Http.json(r.body)
    if type(d) ~= "table" then return nil, "unexpected" end
    local read = tonumber(d.readingProgress)
    if not read and type(d.booksRead) == "string" then
        local list = Http.json(d.booksRead)
        read = type(list) == "table" and #list or 0
    end
    return { goal = tonumber(d.readingGoal) or 0, read = read or 0, days_left = tonumber(d.daysRemaining) }
end

-- The goal form is guarded by a firewall token embedded in the challenge page.
function Api:setGoal(goal)
    goal = math.floor(tonumber(goal) or 0)
    if goal < 1 then return nil, "unexpected" end
    local page = self.http:get(BASE .. "/readingchallenges/annual")
    if page.err then return nil, page.err end
    local body = page.body or ""
    local token = body:match('<input[^>]-name=["\']anti%-csrftoken%-a2z["\'][^>]-value=["\']([^"\']+)["\']')
        or body:match('<input[^>]-value=["\']([^"\']+)["\'][^>]-name=["\']anti%-csrftoken%-a2z["\']')
    if not token then return nil, "unexpected" end
    local r = self.http:request("POST", BASE .. "/readingchallenges/updateGoal?newGoal=" .. goal, {
        xhr = true,
        headers = { ["anti-csrftoken-a2z"] = token, ["Referer"] = BASE .. "/readingchallenges/annual" },
    })
    if r.err then return nil, r.err end
    return goal
end

return Api
