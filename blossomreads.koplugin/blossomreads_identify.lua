--[[--
Find the Goodreads book for a local file.

1. An ISBN or ASIN in the book's identifiers (or file name): Goodreads'
   search by identifier returns that exact edition, so the first hit is it.
2. Otherwise title + author search, scored; linked automatically only when
   the best match scores at least AUTO_SCORE and isn't tied.
KOReader already reads every dc:identifier into doc_props, so no OPF parsing.
--]]

local Identify = {}

Identify.AUTO_SCORE = 85

local function digits(s)
    return (s or ""):upper():gsub("[%s%-]", "")
end

local function validIsbn13(s)
    if not s:match("^97[89]%d%d%d%d%d%d%d%d%d%d$") then return false end
    local sum = 0
    for i = 1, 13 do sum = sum + tonumber(s:sub(i, i)) * (i % 2 == 1 and 1 or 3) end
    return sum % 10 == 0
end

local function validIsbn10(s)
    if not s:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then return false end
    local sum = 0
    for i = 1, 10 do
        local c = s:sub(i, i)
        sum = sum + (c == "X" and 10 or tonumber(c)) * (11 - i)
    end
    return sum % 11 == 0
end

function Identify.isbn13(s)
    s = digits(s)
    if validIsbn13(s) then return s end
    if validIsbn10(s) then
        local core = "978" .. s:sub(1, 9)
        local sum = 0
        for i = 1, 12 do sum = sum + tonumber(core:sub(i, i)) * (i % 2 == 1 and 1 or 3) end
        return core .. tostring((10 - sum % 10) % 10)
    end
end

local function findIsbn(text)
    text = (text or ""):upper()
    for candidate in text:gmatch("[%dX][%dX%-%s]+[%dX]") do
        local isbn = Identify.isbn13(candidate)
        if isbn then return isbn end
    end
end

local function findAsin(text)
    return (text or ""):upper():match("%f[%w](B0[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d])%f[%W]")
end

-- "(2) Moonlit Orchard - Juniper Hale.epub" -> "Moonlit Orchard", "Juniper Hale" (Title - Author).
-- A leading "(n)" series number and [bracketed] / (parenthesised) extras are dropped.
function Identify.fromFileName(file)
    local name = ((file or ""):match("([^/]+)$") or ""):gsub("%.%w+$", "")
    name = name:gsub("^%(%d+%)%s*", ""):gsub("%s*%b[]", ""):gsub("%s*%b()%s*$", "")
    local title, author = name:match("^(.*)%s+%-%s+(.-)%s*$") -- the last " - " separates the author
    if title and title ~= "" and author ~= "" then return title, author end
    return name, nil
end

-- props: KOReader doc_props ({ title, authors = "A\nB", identifiers = "isbn:…\n…" }),
-- or nil for a book never opened (then the file name is used).
function Identify.fromProps(props, file)
    props = props or {}
    local name = (file or ""):match("([^/]+)$") or ""
    local file_title, file_author = Identify.fromFileName(file)
    local title = props.title
    if not title or title == "" then title = file_title end
    local author = (props.authors or ""):match("^([^\n]+)")
    if not author or author == "" then author = file_author end
    return {
        isbn = findIsbn(props.identifiers) or findIsbn(name),
        asin = findAsin(props.identifiers) or findAsin(name),
        title = title,
        author = author,
    }
end

--------------------------------------------------------------------------------
-- Title / author scoring
--------------------------------------------------------------------------------

local function words(s)
    s = (s or ""):lower():gsub("&amp;", "&"):gsub("['’`\".]", ""):gsub("%b()", "")
    local set, n = {}, 0
    for w in s:gmatch("%w+") do
        if not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end

local function similarity(a, b)
    local sa, na = words(a)
    local sb, nb = words(b)
    if na == 0 or nb == 0 then return 0 end
    local both = 0
    for w in pairs(sa) do if sb[w] then both = both + 1 end end
    return both / (na + nb - both)
end

local function core(title)
    return ((title or ""):match("^([^:]+):") or title or "")
end

function Identify.score(want, cand)
    local score = 0
    local t = math.max(similarity(want.title, cand.title), similarity(core(want.title), core(cand.title)))
    if t >= 0.999 then score = score + 50
    elseif t >= 0.85 then score = score + 30
    elseif t >= 0.6 then score = score + 20
    elseif t < 0.3 then score = score - 30 end
    if want.author and cand.author then
        local a = similarity(want.author, cand.author)
        if a >= 0.999 then score = score + 35
        elseif a >= 0.6 then score = score + 20
        elseif a < 0.3 then score = score - 50 end
    end
    return math.max(0, math.min(100, score))
end

-- Returns match, how ("isbn" | "asin" | "title"), ranked candidates (for the picker).
-- search(query) -> list of { gid, title, author, cover } or nil, err.
function Identify.match(search, want)
    for _, key in ipairs({ "isbn", "asin" }) do
        if want[key] then
            local hits = search(want[key])
            if hits and hits[1] then return hits[1], key, hits end
        end
    end
    local query = want.title or ""
    if want.author then query = query .. " " .. want.author end
    local hits, err = search(query)
    if not hits then return nil, nil, nil, err end
    local ranked = {}
    for _, c in ipairs(hits) do
        c.score = Identify.score(want, c)
        ranked[#ranked + 1] = c
    end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    local best = ranked[1]
    if best and best.score >= Identify.AUTO_SCORE and not (ranked[2] and ranked[2].score == best.score) then
        return best, "title", ranked
    end
    return nil, nil, ranked
end

return Identify
