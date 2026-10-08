--[[--
Updates Blossom Reads from its GitHub releases.

check()   finds the newest "blossomreads-vX.Y.Z" release that has the plugin zip.
install() downloads it, checks its SHA-256, unpacks it next to the plugin
          (blossomreads.koplugin.new), makes sure it's a complete plugin, then
          swaps folders, keeping the previous version as blossomreads.koplugin.old
          until the next start. If the swap fails, the previous version is put back.
Nothing is changed until every check has passed. GitHub never sees your
Goodreads cookies: these requests use a fresh client.
--]]

local Http = require("blossomreads_http")

local Update = {}

Update.REPO = "shgmacha/koreader-plugins"
Update.TAG = "blossomreads%-v(%d+%.%d+%.%d+)$"
Update.ASSET = "blossomreads.koplugin.zip"
Update.FOLDER = "blossomreads.koplugin"

--------------------------------------------------------------------------------
-- Versions and releases
--------------------------------------------------------------------------------

local function parts(v)
    local a, b, c = tostring(v or ""):match("(%d+)%.(%d+)%.(%d+)")
    return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
end

function Update.newer(a, b)
    local x, y = parts(a), parts(b)
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

-- The newest published release (not draft / prerelease) with the plugin zip.
function Update.pick(releases)
    local best
    for _, r in ipairs(releases or {}) do
        local version = type(r) == "table" and not r.draft and not r.prerelease and tostring(r.tag_name or ""):match(Update.TAG)
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

-- Returns the newer release (or nil when up to date), err.
function Update.check(current, transport)
    local http = Http.new{ transport = transport }
    local r = http:get("https://api.github.com/repos/" .. Update.REPO .. "/releases?per_page=20", {
        headers = { ["Accept"] = "application/vnd.github+json", ["Referer"] = "https://github.com/" },
    })
    if r.err then return nil, r.err end
    local list = Http.json(r.body)
    if type(list) ~= "table" then return nil, "unexpected" end
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
        f:write(data)
        f:close()
        return true
    end,
}

local function sha256(data)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then return sha2.sha256(data) end
end

-- A path inside the zip is safe when it stays inside blossomreads.koplugin/.
function Update.safePath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) then return false end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return path:sub(1, #Update.FOLDER + 1) == Update.FOLDER .. "/"
end

--------------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------------

-- Unpack the zip's blossomreads.koplugin/ into `dest` (which becomes the plugin folder).
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

-- info from check(); plugin_dir = this plugin's folder.
-- opts = { transport, archiver, sha256, fs } (all optional, for tests).
-- Returns version or nil, err ("network" | "checksum" | "bad_zip" | "incomplete" | "write" | "swap").
function Update.install(info, plugin_dir, opts)
    opts = opts or {}
    local fs = opts.fs or Update.fs
    local http = Http.new{ transport = opts.transport }
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    local staging, backup = plugin_dir .. ".new", plugin_dir .. ".old"
    local zip_path = parent .. "/" .. Update.ASSET .. ".download"

    local r = http:get(info.zip_url, { headers = { ["Accept"] = "application/octet-stream" } })
    if r.err or not r.body or #r.body == 0 then return nil, r.err or "network" end
    if info.sha_url then
        local s = http:get(info.sha_url)
        local want = not s.err and (s.body or ""):match("%x+")
        local got = (opts.sha256 or sha256)(r.body)
        if not want or not got or got:lower() ~= want:lower() then return nil, "checksum" end
    end
    if not fs.write(zip_path, r.body) then return nil, "write" end

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
