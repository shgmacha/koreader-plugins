--[[--
Cookie-jar HTTP for Goodreads (and Amazon's sign-in pages).

* One cookie jar for every hop, rotated from Set-Cookie (deletions included).
* Redirects followed by hand so cookies survive them.
* Errors classified into a few codes. Only a real sign-in page counts as
  "signin": firewall pages (403/202/challenge) are "blocked" and never end
  the session, unlike goodreadskosync which logged people out on false alarms.
--]]

local Http = {}
Http.__index = Http

Http.ERR = {
    NETWORK = "network",  -- no answer
    SIGNIN = "signin",    -- Goodreads wants a fresh sign-in
    BLOCKED = "blocked",  -- firewall / bot check
    NOT_FOUND = "not_found",
    SERVER = "server",    -- 5xx, 429, anything unexpected
}

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
local SIGNIN_PATHS = { "/user/sign_in", "/ap/signin" }
local ATTRS = {
    path = true, domain = true, expires = true, ["max-age"] = true, samesite = true,
    secure = true, httponly = true, version = true, partitioned = true, priority = true,
}
-- A stale GraphQL token in the jar makes Goodreads reject the whole request.
local DROP = { jwt_token = true }

--------------------------------------------------------------------------------
-- Cookies
--------------------------------------------------------------------------------

local function parseJar(jar)
    local map, order = {}, {}
    for name, value in (jar or ""):gmatch("([^=;%s]+)=([^;]*)") do
        if not ATTRS[name:lower()] and not DROP[name] then
            if not map[name] then order[#order + 1] = name end
            map[name] = value
        end
    end
    return map, order
end

local function joinJar(map, order)
    local parts = {}
    for _, name in ipairs(order) do
        if map[name] and map[name] ~= "" then parts[#parts + 1] = name .. "=" .. map[name] end
    end
    return table.concat(parts, "; ")
end

-- LuaSocket folds repeated Set-Cookie headers with ", ", and Expires dates
-- contain commas too, so split only where a new "name=" starts a cookie.
local function splitSetCookie(header)
    local cookies, current = {}, nil
    for piece in (header .. ","):gmatch("([^,]*),") do
        local head = piece:match("^%s*([^=;%s]+)=")
        local looks_new = head and not ATTRS[head:lower()] and not piece:match("^%s*%d")
        if looks_new or not current then
            current = piece
            cookies[#cookies + 1] = current
        else
            cookies[#cookies] = cookies[#cookies] .. "," .. piece
        end
    end
    return cookies
end

function Http.mergeSetCookie(jar, set_cookie)
    local map, order = parseJar(jar)
    if type(set_cookie) == "string" and set_cookie ~= "" then
        for _, cookie in ipairs(splitSetCookie(set_cookie)) do
            local name, value = cookie:match("^%s*([^=;%s]+)=([^;]*)")
            if name and not DROP[name] and not ATTRS[name:lower()] then
                value = value:match("^%s*(.-)%s*$")
                local lower = cookie:lower()
                local deleted = value == "" or lower:find("max%-age=0") or lower:find("expires=[^;]-1970")
                if deleted then
                    map[name] = nil
                else
                    if not map[name] then order[#order + 1] = name end
                    map[name] = value
                end
            end
        end
    end
    return joinJar(map, order)
end

--------------------------------------------------------------------------------
-- Encoding / JSON
--------------------------------------------------------------------------------

function Http.urlencode(v)
    return (tostring(v or ""):gsub("\n", "\r\n"):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

function Http.form(fields)
    local parts = {}
    for k, v in pairs(fields or {}) do
        parts[#parts + 1] = Http.urlencode(k) .. "=" .. Http.urlencode(v)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

function Http.absolute(base, location)
    if not location or location == "" or location:match("^https?://") then return location end
    if location:sub(1, 2) == "//" then return "https:" .. location end
    local origin = (base or ""):match("^(https?://[^/]+)") or base
    if location:sub(1, 1) == "/" then return origin .. location end
    local dir = (base or ""):match("^(https?://.*/)") or (origin .. "/")
    return dir .. location
end

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- Small decoder for when KOReader's json modules aren't there (tests).
local function decode(s)
    local i = 1
    local value
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local function str()
        local out = {}
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == "" then error("eof") end
            if c == '"' then i = i + 1; return table.concat(out) end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                if e == "u" then
                    out[#out + 1] = utf8char(tonumber(s:sub(i + 2, i + 5), 16))
                    i = i + 6
                else
                    out[#out + 1] = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e] or e
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
    end
    value = function()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local obj = {}
            i = i + 1; ws()
            if s:sub(i, i) == "}" then i = i + 1; return obj end
            repeat
                ws()
                local k = str(); ws()
                i = i + 1 -- ':'
                obj[k] = value(); ws()
                c = s:sub(i, i); i = i + 1
            until c ~= ","
            return obj
        elseif c == "[" then
            local arr = {}
            i = i + 1; ws()
            if s:sub(i, i) == "]" then i = i + 1; return arr end
            repeat
                arr[#arr + 1] = value(); ws()
                c = s:sub(i, i); i = i + 1
            until c ~= ","
            return arr
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then error("bad json") end
        i = i + #num
        return tonumber(num)
    end
    return value()
end

function Http.json(text)
    if type(text) ~= "string" or text == "" then return nil end
    for _, name in ipairs({ "rapidjson", "json" }) do
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" and mod.decode then
            local fine, v = pcall(mod.decode, text)
            return fine and v or nil
        end
    end
    local fine, v = pcall(decode, text)
    return fine and v or nil
end

--------------------------------------------------------------------------------
-- Transport (LuaSocket; injectable for tests)
--------------------------------------------------------------------------------

local function socketTransport(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")
    local sink = {}
    if ok_su then socketutil:set_timeout(5, 15) end
    local ok, r, code, headers = pcall(http.request, {
        url = req.url,
        method = req.method,
        headers = req.headers,
        source = req.body and ltn12.source.string(req.body) or nil,
        sink = ltn12.sink.table(sink),
        redirect = false,
    })
    if ok_su then socketutil:reset_timeout() end
    if not ok or not r then return nil end
    return tonumber(code), headers or {}, table.concat(sink)
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

function Http.new(opts)
    opts = opts or {}
    return setmetatable({
        cookies = Http.mergeSetCookie(opts.cookies or "", nil),
        base = opts.base or "https://www.goodreads.com",
        transport = opts.transport or socketTransport,
        max_hops = 8,
    }, Http)
end

local function isSignin(url)
    for _, p in ipairs(SIGNIN_PATHS) do
        if url and url:find(p, 1, true) then return true end
    end
    return false
end

function Http.classify(status, headers, url)
    if not status then return Http.ERR.NETWORK end
    if status == 202 then return Http.ERR.BLOCKED end
    for _, v in pairs(headers or {}) do
        if type(v) == "string" and v:lower():find("challenge", 1, true) then return Http.ERR.BLOCKED end
    end
    if status == 401 then return Http.ERR.SIGNIN end
    if status == 403 then return Http.ERR.BLOCKED end
    if status == 404 then return Http.ERR.NOT_FOUND end
    if status < 200 or status >= 300 then return Http.ERR.SERVER end
    if isSignin(url) then return Http.ERR.SIGNIN end
    return nil
end

-- opts: body (string or table), headers, csrf (token string), xhr (bool),
-- signin_ok (sign-in pages are the expected answer, used by the login flow).
-- Returns { status, body, headers, url, err }.
function Http:request(method, url, opts)
    opts = opts or {}
    local body = opts.body
    if type(body) == "table" then body = Http.form(body) end
    local hops, resp = 0, nil
    while true do
        local headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept-Language"] = "en-US,en;q=0.9",
            ["Accept"] = opts.xhr and "application/json, text/javascript, */*; q=0.01"
                or "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Referer"] = self.base .. "/",
        }
        if self.cookies ~= "" then headers["Cookie"] = self.cookies end
        if body then
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            headers["Content-Length"] = tostring(#body)
            headers["Origin"] = url:match("^(https?://[^/]+)")
        end
        if opts.xhr then headers["X-Requested-With"] = "XMLHttpRequest" end
        if opts.csrf then headers["X-CSRF-Token"] = opts.csrf end
        for k, v in pairs(opts.headers or {}) do headers[k] = v end

        local status, raw, text = self.transport({ method = method, url = url, headers = headers, body = body })
        local h = {}
        for k, v in pairs(raw or {}) do h[tostring(k):lower()] = v end
        if h["set-cookie"] then self.cookies = Http.mergeSetCookie(self.cookies, h["set-cookie"]) end
        resp = { status = status, body = text, headers = h, url = url }

        local redirect = status == 301 or status == 302 or status == 303 or status == 307 or status == 308
        if not (redirect and h.location and hops < self.max_hops) then break end
        url = Http.absolute(url, h.location)
        if status ~= 307 and status ~= 308 then method, body = "GET", nil end
        hops = hops + 1
    end
    resp.err = Http.classify(resp.status, resp.headers, resp.url)
    if resp.err == Http.ERR.SIGNIN and opts.signin_ok then resp.err = nil end
    return resp
end

function Http:get(url, opts)
    return self:request("GET", url, opts)
end

function Http:post(url, fields, opts)
    opts = opts or {}
    opts.body = fields or ""
    return self:request("POST", url, opts)
end

return Http
