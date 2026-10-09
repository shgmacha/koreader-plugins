--[[--
Blossom's updater: finds the newest GitHub Release of this plugin and installs it safely.

Releases live in shgmacha/koreader-plugins with tags like `blossom-v1.1.0` and a
`blossom.koplugin.zip` asset (plus an optional `blossom.koplugin.zip.sha256`).

The pure helpers (versions, picking a release, path safety) need nothing from KOReader.
Everything that touches the network or the disk goes through `io`, so tests can fake it.
--]]

local Update = {}

Update.REPO = "shgmacha/koreader-plugins"
Update.API = "https://api.github.com/repos/" .. Update.REPO .. "/releases"
Update.DAY = 24 * 60 * 60

-- Pure helpers ------------------------------------------------------------------

--- Numeric parts of "1.10.0" -> { 1, 10, 0 }; nil when it isn't a version.
function Update.parseVersion(v)
    if type(v) ~= "string" or not v:match("^%d+[%d%.]*$") then return end
    local parts = {}
    for n in v:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

--- -1, 0 or 1, comparing segment by segment (1.10.0 > 1.9.2, 1.0 == 1.0.0).
function Update.compareVersions(a, b)
    local pa, pb = Update.parseVersion(a) or {}, Update.parseVersion(b) or {}
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

--- The newest published release whose tag is `<prefix>-v<version>` (never another plugin's).
--- Returns release, version.
function Update.pickRelease(releases, prefix)
    local best, best_v
    local pattern = "^" .. prefix:gsub("%p", "%%%0") .. "%-v(%d[%d%.]*)$"
    for _, r in ipairs(type(releases) == "table" and releases or {}) do
        local v = type(r) == "table" and not r.draft and not r.prerelease
            and type(r.tag_name) == "string" and r.tag_name:match(pattern)
        if v and (not best_v or Update.compareVersions(v, best_v) > 0) then
            best, best_v = r, v
        end
    end
    return best, best_v
end

function Update.findAsset(release, name)
    for _, a in ipairs(release and release.assets or {}) do
        if a.name == name then return a end
    end
end

--- True when a zip entry stays inside `root/` (no absolute paths, no "..").
function Update.safeEntry(path, root)
    if type(path) ~= "string" or path == "" then return false end
    if path:sub(1, 1) == "/" or path:match("^%a:") or path:find("\\", 1, true) then return false end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return path == root or path == root .. "/" or path:sub(1, #root + 1) == root .. "/"
end

--- The hash in a ".sha256" file ("<hex>  name" or just "<hex>"), lower-cased.
function Update.parseChecksum(text)
    local hex = type(text) == "string" and text:match("^%s*(%x+)")
    return hex and #hex == 64 and hex:lower() or nil
end

-- Checking ------------------------------------------------------------------------

--- io = { getJSON = function(url) -> table|nil, err }
--- Returns { version, release, newer = bool } or nil, err.
function Update.check(io, prefix, current)
    local releases, err = io.getJSON(Update.API)
    if not releases then return nil, err or "network" end
    local release, version = Update.pickRelease(releases, prefix)
    if not release then return { newer = false, version = current } end
    return { release = release, version = version, newer = Update.compareVersions(version, current) > 0 }
end

-- Installing ------------------------------------------------------------------------

--[[
io = {
    download = function(url, dest) -> true | nil, err
    readFile = function(path) -> string | nil
    sha256   = function(data) -> hex
    unzip    = function(zip, dest, keep) -> true | nil, err   -- extracts entries where keep(path) is true
    exists   = function(path) -> bool
    rename   = function(from, to) -> true | nil, err
    purge    = function(path)                                 -- removes a folder (if there)
    mkdir    = function(path)
}
opts = { name = "blossom.koplugin", plugin_dir = ".../plugins/blossom.koplugin", work_dir = "...", release = {...}, version = "1.1.0" }
Returns true, or nil + a reason; nothing in plugin_dir changes unless everything checked out.
--]]
function Update.install(io, opts)
    local name, plugin_dir, work = opts.name, opts.plugin_dir, opts.work_dir
    local zip_name = name .. ".zip"
    local asset = Update.findAsset(opts.release, zip_name)
    if not asset or not asset.browser_download_url then return nil, "no_asset" end

    io.mkdir(work)
    local zip_path = work .. "/" .. zip_name
    local ok, err = io.download(asset.browser_download_url, zip_path)
    if not ok then return nil, "download", err end

    -- Checksum, when the release has one.
    local sum_asset = Update.findAsset(opts.release, zip_name .. ".sha256")
    if sum_asset and sum_asset.browser_download_url then
        local sum_path = zip_path .. ".sha256"
        local ok_sum = io.download(sum_asset.browser_download_url, sum_path)
        local expected = ok_sum and Update.parseChecksum(io.readFile(sum_path))
        local data = io.readFile(zip_path)
        if not expected or not data or io.sha256(data) ~= expected then return nil, "checksum" end
    end

    -- Unpack next to the plugin, then make sure it's a whole plugin.
    local parent = plugin_dir:match("^(.*)/[^/]+/?$")
    local staging = parent .. "/" .. name .. ".new"
    io.purge(staging)
    io.mkdir(staging)
    local unzipped, uerr = io.unzip(zip_path, staging, function(path) return Update.safeEntry(path, name) end)
    local new_dir = staging .. "/" .. name
    if not unzipped or not io.exists(new_dir .. "/_meta.lua") or not io.exists(new_dir .. "/main.lua") then
        io.purge(staging)
        return nil, "bad_zip", uerr
    end

    -- Swap: current -> .old, new -> current; put the old one back if the second step fails.
    local old = parent .. "/" .. name .. ".old"
    io.purge(old)
    local moved, merr = io.rename(plugin_dir, old)
    if not moved then
        io.purge(staging)
        return nil, "not_writable", merr
    end
    local swapped, serr = io.rename(new_dir, plugin_dir)
    if not swapped then
        io.rename(old, plugin_dir)
        io.purge(staging)
        return nil, "swap", serr
    end
    io.purge(staging)
    return true
end

--- Leftovers from an earlier update (the .old backup, a half-done .new) — removed at start.
function Update.cleanup(io, plugin_dir, name)
    local parent = plugin_dir:match("^(.*)/[^/]+/?$")
    if not parent then return end
    io.purge(parent .. "/" .. name .. ".old")
    io.purge(parent .. "/" .. name .. ".new")
end

-- KOReader io ------------------------------------------------------------------------

--- The real io, built from KOReader's modules (only called on a device / in the emulator).
function Update.kindleIO()
    local lfs = require("libs/libkoreader-lfs")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")

    -- GET with redirects followed by hand (GitHub sends downloads to another host).
    local function get(url, sink, hops)
        hops = hops or 0
        if ok_su then socketutil:set_timeout(10, 60) end
        local ok, r, code, headers = pcall(http.request, {
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "Blossom-KOReader", ["Accept"] = "application/vnd.github+json" },
            sink = sink,
            redirect = false,
        })
        if ok_su then socketutil:reset_timeout() end
        if not ok or not r then return nil, tostring(code or r) end
        code = tonumber(code)
        if code and code >= 300 and code < 400 and headers and headers.location and hops < 5 then
            return get(headers.location, sink, hops + 1)
        end
        if code ~= 200 then return nil, "http " .. tostring(code) end
        return true
    end

    local io_ = {}
    function io_.getJSON(url)
        local chunks = {}
        local ok, err = get(url, ltn12.sink.table(chunks))
        if not ok then return nil, err end
        local ok_json, data = pcall(require("json").decode, table.concat(chunks))
        if not ok_json then return nil, "json" end
        return data
    end
    function io_.download(url, dest)
        local f = io.open(dest, "wb")
        if not f then return nil, "cannot write " .. dest end
        local ok, err = get(url, ltn12.sink.file(f))
        if not ok then os.remove(dest) end
        return ok, err
    end
    function io_.readFile(path)
        local f = io.open(path, "rb")
        if not f then return end
        local data = f:read("*a")
        f:close()
        return data
    end
    function io_.sha256(data) return require("ffi/sha2").sha256(data) end
    function io_.exists(path) return lfs.attributes(path, "mode") ~= nil end
    function io_.rename(from, to) return os.rename(from, to) end
    function io_.mkdir(path) require("util").makePath(path) end
    function io_.purge(path)
        if lfs.attributes(path, "mode") == "directory" then require("ffi/util").purgeDir(path) end
    end
    function io_.unzip(zip, dest, keep)
        local ok_arc, Archiver = pcall(require, "ffi/archiver")
        if ok_arc and Archiver and Archiver.Reader then
            local reader = Archiver.Reader:new()
            if not reader:open(zip) then return nil, reader.err end
            local entries = {}
            for entry in reader:iterate() do entries[#entries + 1] = entry end
            for _, entry in ipairs(entries) do
                if not keep(entry.path) then
                    reader:close()
                    return nil, "unsafe path " .. tostring(entry.path)
                end
            end
            for _, entry in ipairs(entries) do
                local target = dest .. "/" .. entry.path:gsub("/$", "")
                if entry.mode == "directory" then
                    require("util").makePath(target)
                elseif entry.mode == "file" then
                    require("util").makePath((target:match("^(.*)/[^/]+$")))
                    if not reader:extractToPath(entry.path, target) then
                        local xerr = reader.err
                        reader:close()
                        return nil, xerr or "extract failed"
                    end
                end
            end
            reader:close()
            return true
        end
        -- Older KOReader: busybox unzip (list first so unsafe paths are refused before writing).
        local list = io.popen(string.format("unzip -Z1 %q 2>/dev/null", zip))
        if not list then return nil, "no unzip" end
        for path in list:lines() do
            if not keep(path) then
                list:close()
                return nil, "unsafe path " .. path
            end
        end
        list:close()
        local rc = os.execute(string.format("unzip -o -q %q -d %q", zip, dest))
        return rc == 0 or rc == true, "unzip failed"
    end
    return io_
end

return Update
