--[[--
Updates Page Frame from its GitHub releases.

check()   finds the newest "pageframe-vX.Y.Z" release that has the plugin zip.
install() downloads it, checks its SHA-256, unpacks it next to the plugin
          (pageframe.koplugin.new), makes sure it's a complete plugin, then swaps
          folders, keeping the previous version as pageframe.koplugin.old until the
          next start. If the swap fails, the previous version is put back.
Nothing is changed until every check has passed. Frames in koreader/frames/ live
outside the plugin folder, so an update never touches them.
--]]

local Update = {}

Update.REPO = "shgmacha/koreader-plugins"
Update.TAG = "pageframe%-v(%d+%.%d+%.%d+)$"
Update.ASSET = "pageframe.koplugin.zip"
Update.FOLDER = "pageframe.koplugin"
Update.API = "https://api.github.com/repos/" .. Update.REPO .. "/releases?per_page=30"
Update.MAX_HOPS = 5

--------------------------------------------------------------------------------
-- HTTP (LuaSocket; a transport can be injected for tests)
--------------------------------------------------------------------------------

-- transport(req) -> status, headers, body   (nil on a network error)
local function socketTransport(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")
    local sink = {}
    if ok_su then socketutil:set_timeout(5, 30) end
    local ok, r, code, headers = pcall(http.request, {
        url = req.url,
        method = "GET",
        headers = req.headers,
        sink = ltn12.sink.table(sink),
        redirect = false,
    })
    if ok_su then socketutil:reset_timeout() end
    if not ok or not r then return nil end
    return tonumber(code), headers or {}, table.concat(sink)
end

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

function Update.absolute(base, location)
    if location:match("^%a[%w+.-]*://") then return location end
    local origin = base:match("^(%a[%w+.-]*://[^/]+)")
    if location:sub(1, 1) == "/" then return origin .. location end
    return (base:match("^(.*/)") or (origin .. "/")) .. location
end

--- GET with redirects (GitHub's asset links redirect to its file storage).
-- @treturn int|nil status, string body
function Update.get(url, headers, transport)
    transport = transport or socketTransport
    headers = headers or {}
    headers["User-Agent"] = headers["User-Agent"] or "KOReader-PageFrame"
    for _ = 0, Update.MAX_HOPS do
        local status, resp_headers, body = transport({ url = url, headers = headers })
        if not status then return nil end
        if not REDIRECT[status] then return status, body end
        local location = resp_headers and (resp_headers.location or resp_headers.Location)
        if not location then return nil end
        url = Update.absolute(url, location)
    end
    return nil -- too many redirects
end

function Update.decode(text)
    if type(text) ~= "string" or text == "" then return nil end
    for _, name in ipairs({ "rapidjson", "json" }) do
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" and mod.decode then
            local fine, v = pcall(mod.decode, text)
            return fine and v or nil
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Versions and releases
--------------------------------------------------------------------------------

local function parts(v)
    local a, b, c = tostring(v or ""):match("(%d+)%.(%d+)%.(%d+)")
    return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
end

--- Is version a newer than version b?
function Update.newer(a, b)
    local x, y = parts(a), parts(b)
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

-- The newest published release (not draft / prerelease) of Page Frame with the plugin zip.
function Update.pick(releases)
    local best
    for _, r in ipairs(type(releases) == "table" and releases or {}) do
        local version = type(r) == "table" and not r.draft and not r.prerelease
            and tostring(r.tag_name or ""):match(Update.TAG)
        if version then
            local zip, sha
            for _, a in ipairs(r.assets or {}) do
                if a.name == Update.ASSET then zip = a.browser_download_url end
                if a.name == Update.ASSET .. ".sha256" then sha = a.browser_download_url end
            end
            if zip and (not best or Update.newer(version, best.version)) then
                best = { version = version, zip_url = zip, sha_url = sha, notes = r.body, page = r.html_url }
            end
        end
    end
    return best
end

--- The newer release, or nil when up to date; nil, "network" when GitHub can't be read.
-- @tparam string current this plugin's version
-- @tparam[opt] table opts transport, decode (for tests)
function Update.check(current, opts)
    opts = opts or {}
    local status, body = Update.get(Update.API, { ["Accept"] = "application/vnd.github+json" }, opts.transport)
    if status ~= 200 then return nil, "network" end
    local list = (opts.decode or Update.decode)(body)
    if type(list) ~= "table" then return nil, "network" end
    local best = Update.pick(list)
    if best and Update.newer(best.version, current) then return best end
    return nil
end

--------------------------------------------------------------------------------
-- Files (overridable for tests)
--------------------------------------------------------------------------------

local function shell(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

Update.fs = {
    isDir = function(p)
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs then return lfs.attributes(p, "mode") == "directory" end
        return os.execute("test -d " .. shell(p)) == 0
    end,
    isFile = function(p)
        local f = io.open(p, "rb")
        if f then f:close() end
        return f ~= nil
    end,
    mkdir = function(p) os.execute("mkdir -p " .. shell(p)) end,
    remove = function(p) os.execute("rm -rf " .. shell(p)) end,
    rename = function(a, b) return os.rename(a, b) end,
    write = function(p, data)
        local f = io.open(p, "wb")
        if not f then return false end
        local ok = f:write(data)
        f:close()
        return ok ~= nil
    end,
}

local function sha256(data)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then return sha2.sha256(data) end
end

-- A path inside the zip is safe when it stays inside pageframe.koplugin/.
function Update.safePath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return path:sub(1, #Update.FOLDER + 1) == Update.FOLDER .. "/"
end

--------------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------------

-- Unpack the zip's pageframe.koplugin/ into `dest` (which becomes the plugin folder).
local function unpack(archiver, zip_path, dest, fs)
    local reader = archiver.Reader:new()
    if not reader:open(zip_path) then return nil, "bad_zip" end
    local files = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if not Update.safePath(entry.path) then
                reader:close()
                return nil, "bad_zip"
            end
            files[#files + 1] = entry.path
        end
    end
    for _, path in ipairs(files) do
        local data = reader:extractToMemory(path)
        if not data then
            reader:close()
            return nil, "bad_zip"
        end
        local target = dest .. "/" .. path:sub(#Update.FOLDER + 2)
        fs.mkdir(target:match("^(.*)/[^/]*$"))
        if not fs.write(target, data) then
            reader:close()
            return nil, "write"
        end
    end
    reader:close()
    return true
end

--- Download, verify and swap in a release.
-- @tparam table info from check()
-- @string plugin_dir this plugin's folder
-- @tparam[opt] table opts transport, archiver, sha256, fs (for tests)
-- @treturn string|nil version, or nil and "network" | "checksum" | "bad_zip" | "incomplete" | "write" | "swap"
function Update.install(info, plugin_dir, opts)
    opts = opts or {}
    local fs = opts.fs or Update.fs
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    local staging, backup = plugin_dir .. ".new", plugin_dir .. ".old"
    local zip_path = parent .. "/" .. Update.ASSET .. ".download"

    local status, body = Update.get(info.zip_url, { ["Accept"] = "application/octet-stream" }, opts.transport)
    if status ~= 200 or not body or #body == 0 then return nil, "network" end
    if info.sha_url then
        local s_status, s_body = Update.get(info.sha_url, nil, opts.transport)
        local want = s_status == 200 and (s_body or ""):match("%x+")
        local got = (opts.sha256 or sha256)(body)
        if not want or not got or got:lower() ~= want:lower() then return nil, "checksum" end
    end
    if not fs.write(zip_path, body) then return nil, "write" end

    fs.remove(staging)
    fs.mkdir(staging)
    local ok, err = unpack(opts.archiver or require("ffi/archiver"), zip_path, staging, fs)
    fs.remove(zip_path)
    if not ok then
        fs.remove(staging)
        return nil, err
    end
    if not (fs.isFile(staging .. "/_meta.lua") and fs.isFile(staging .. "/main.lua")) then
        fs.remove(staging)
        return nil, "incomplete"
    end

    fs.remove(backup)
    if not fs.rename(plugin_dir, backup) then
        fs.remove(staging)
        return nil, "swap"
    end
    if not fs.rename(staging, plugin_dir) then
        fs.rename(backup, plugin_dir) -- put the running version back
        fs.remove(staging)
        return nil, "swap"
    end
    return info.version
end

-- Remove what an earlier update left behind (called when the plugin starts).
function Update.cleanup(plugin_dir, fs)
    fs = fs or Update.fs
    for _, suffix in ipairs({ ".old", ".new" }) do
        if fs.isDir(plugin_dir .. suffix) then fs.remove(plugin_dir .. suffix) end
    end
end

return Update
