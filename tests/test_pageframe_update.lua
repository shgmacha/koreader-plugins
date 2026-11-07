-- Page Frame's updater: releases, redirects, and the install swap, with a fake network,
-- disk and zip reader.
local H = require("tests.harness")
package.path = "./pageframe.koplugin/?.lua;" .. package.path
local Update = require("pageframe_update")
local test, eq = H.test, H.eq

-- Fake network: url -> { status, headers, body }; records every request.
local function net(routes)
    local seen = {}
    local transport = function(req)
        seen[#seen + 1] = req.url
        local r = routes[req.url]
        if not r then return nil end
        return r[1], r[2] or {}, r[3]
    end
    return transport, seen
end

-- Fake disk: a table of path -> data, with folders as true.
local function disk(opts)
    opts = opts or {}
    local files, dirs, log = {}, {}, {}
    local fs = {
        isDir = function(p) return dirs[p] == true end,
        isFile = function(p) return files[p] ~= nil end,
        mkdir = function(p) dirs[p] = true end,
        remove = function(p)
            dirs[p] = nil
            for k in pairs(files) do
                if k == p or k:sub(1, #p + 1) == p .. "/" then files[k] = nil end
            end
            for k in pairs(dirs) do
                if k:sub(1, #p + 1) == p .. "/" then dirs[k] = nil end
            end
        end,
        rename = function(a, b)
            log[#log + 1] = a .. " -> " .. b
            if opts.fail_rename and opts.fail_rename(a, b) then return false end
            if not dirs[a] then return false end
            local moved = {}
            for k, v in pairs(files) do
                if k == a or k:sub(1, #a + 1) == a .. "/" then moved[b .. k:sub(#a + 1)] = v; files[k] = nil end
            end
            for k, v in pairs(moved) do files[k] = v end
            dirs[a], dirs[b] = nil, true
            return true
        end,
        write = function(p, data)
            if opts.fail_write then return false end
            files[p] = data
            return true
        end,
    }
    return fs, files, dirs, log
end

-- Fake zip reader over a list of { path, data } entries.
local function archiver(entries)
    return { Reader = { new = function()
        local r = {}
        function r:open() return entries ~= "corrupt" end
        function r:iterate()
            local i = 0
            return function()
                i = i + 1
                local e = entries[i]
                if e then return { path = e[1], mode = e[2] == nil and "dir" or "file" } end
            end
        end
        function r:extractToMemory(path)
            for _, e in ipairs(entries) do if e[1] == path then return e[2] end end
        end
        function r:close() end
        return r
    end } }
end

local function sha(data) return string.format("%064x", #data * 7919) end -- hex, like a real SHA-256

local PLUGIN = "/k/plugins/pageframe.koplugin"
local ZIP_URL = "https://github.com/x/pageframe.koplugin.zip"
local SHA_URL = "https://github.com/x/pageframe.koplugin.zip.sha256"
local ZIP = "PK-fake-zip-bytes"

local GOOD_ZIP = {
    { "pageframe.koplugin/" },
    { "pageframe.koplugin/_meta.lua", "meta 1.1.0" },
    { "pageframe.koplugin/main.lua", "main 1.1.0" },
    { "pageframe.koplugin/fonts/OFL.txt", "license" },
}

local function installedDisk()
    local fs, files, dirs, log = disk()
    dirs[PLUGIN] = true
    files[PLUGIN .. "/_meta.lua"] = "meta 1.0.0"
    files[PLUGIN .. "/main.lua"] = "main 1.0.0"
    return fs, files, dirs, log
end

local INFO = { version = "1.1.0", zip_url = ZIP_URL, sha_url = SHA_URL }
local function goodNet(extra)
    local routes = {
        [ZIP_URL] = { 302, { location = "https://objects.example/zip?sig=1" } },
        ["https://objects.example/zip?sig=1"] = { 200, {}, ZIP },
        [SHA_URL] = { 200, {}, sha(ZIP) .. "  pageframe.koplugin.zip\n" },
    }
    for k, v in pairs(extra or {}) do routes[k] = v end
    return net(routes)
end

-- Versions and releases --------------------------------------------------------

test("newer: numeric, segment by segment", function()
    eq(Update.newer("1.10.0", "1.9.9"), true)
    eq(Update.newer("1.1.0", "1.1.0"), false)
    eq(Update.newer("1.0.9", "1.1.0"), false)
    eq(Update.newer("2.0.0", nil), true)
end)

local function release(tag, opts)
    opts = opts or {}
    local r = { tag_name = tag, draft = opts.draft, prerelease = opts.prerelease, body = "notes " .. tag,
                html_url = "https://github.com/r/" .. tag, assets = {} }
    if not opts.no_zip then
        r.assets[1] = { name = "pageframe.koplugin.zip", browser_download_url = "zip-" .. tag }
        r.assets[2] = { name = "pageframe.koplugin.zip.sha256", browser_download_url = "sha-" .. tag }
    end
    return r
end

test("pick: newest Page Frame release only; others, drafts, prereleases and zip-less skipped", function()
    local list = {
        release("goodreadssync-v9.0.0"),
        release("pageframe-v1.4.0", { draft = true }),
        release("pageframe-v1.3.0", { prerelease = true }),
        release("pageframe-v1.2.5", { no_zip = true }),
        release("pageframe-v1.10.0"),
        release("pageframe-v1.9.0"),
        release("pageframe-vX"),
        "junk",
    }
    local best = Update.pick(list)
    eq({ best.version, best.zip_url, best.sha_url, best.notes }, { "1.10.0", "zip-pageframe-v1.10.0",
        "sha-pageframe-v1.10.0", "notes pageframe-v1.10.0" })
    eq(Update.pick({}), nil)
    eq(Update.pick(nil), nil)
end)

-- check ------------------------------------------------------------------------

local function api(status, body)
    return net({ [Update.API] = { status, {}, body } })
end
local function decodeAs(value) return function() return value end end

test("check: a newer release is returned", function()
    local transport = api(200, "[...]")
    local info = Update.check("1.0.0", { transport = transport,
        decode = decodeAs({ release("pageframe-v1.1.0"), release("pageframe-v1.0.0") }) })
    eq(info.version, "1.1.0")
end)

test("check: up to date gives nil and no error", function()
    local info, err = Update.check("1.1.0", { transport = api(200, "[...]"),
        decode = decodeAs({ release("pageframe-v1.1.0") }) })
    eq({ info, err }, {})
end)

test("check: GitHub errors and bad JSON are network errors", function()
    eq({ Update.check("1.0.0", { transport = api(403, "rate limited"), decode = decodeAs({}) }) }, { nil, "network" })
    eq({ Update.check("1.0.0", { transport = api(200, "<html>"), decode = decodeAs(nil) }) }, { nil, "network" })
    eq({ Update.check("1.0.0", { transport = net({}) }) }, { nil, "network" }) -- offline
end)

test("check: asks the GitHub API for this repo's releases", function()
    local transport, seen = api(200, "[]")
    Update.check("1.0.0", { transport = transport, decode = decodeAs({}) })
    eq(seen, { "https://api.github.com/repos/shgmacha/koreader-plugins/releases?per_page=30" })
end)

-- get --------------------------------------------------------------------------

test("get: follows redirects, absolute and relative", function()
    local transport, seen = net({
        ["https://a.example/one"] = { 302, { location = "/two" } },
        ["https://a.example/two"] = { 301, { Location = "https://b.example/three" } },
        ["https://b.example/three"] = { 200, {}, "done" },
    })
    eq({ Update.get("https://a.example/one", nil, transport) }, { 200, "done" })
    eq(seen, { "https://a.example/one", "https://a.example/two", "https://b.example/three" })
end)

test("get: gives up after 5 redirects", function()
    local routes = {}
    for i = 0, 6 do routes["https://a.example/" .. i] = { 302, { location = "/" .. (i + 1) } } end
    routes["https://a.example/7"] = { 200, {}, "too far" }
    local transport, seen = net(routes)
    eq(Update.get("https://a.example/0", nil, transport), nil)
    eq(#seen, 6)
end)

test("get: a redirect without a Location, or a network error, gives nil", function()
    eq(Update.get("https://a.example/x", nil, net({ ["https://a.example/x"] = { 302, {} } })), nil)
    eq(Update.get("https://a.example/y", nil, net({})), nil)
end)

test("get: sends a User-Agent (the GitHub API requires one)", function()
    local got
    Update.get("https://a.example/", { Accept = "x" }, function(req) got = req.headers; return 200, {}, "" end)
    eq({ got.Accept, got["User-Agent"] }, { "x", "KOReader-PageFrame" })
end)

-- safePath ---------------------------------------------------------------------

test("safePath: only paths inside pageframe.koplugin/", function()
    eq(Update.safePath("pageframe.koplugin/main.lua"), true)
    eq(Update.safePath("pageframe.koplugin/fonts/OFL.txt"), true)
    eq(Update.safePath("pageframe.koplugin/../x.lua"), false)
    eq(Update.safePath("/etc/passwd"), false)
    eq(Update.safePath("pageframe.koplugin\\main.lua"), false)
    eq(Update.safePath("goodreadssync.koplugin/main.lua"), false)
    eq(Update.safePath("pageframe.kopluginX/main.lua"), false)
    eq(Update.safePath(""), false)
    eq(Update.safePath(nil), false)
end)

-- install ----------------------------------------------------------------------

test("install: downloads through the redirect, verifies, unpacks and swaps", function()
    local fs, files, dirs = installedDisk()
    local transport = goodNet()
    local v = Update.install(INFO, PLUGIN, { transport = transport, archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })
    eq(v, "1.1.0")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.1.0")
    eq(files[PLUGIN .. "/fonts/OFL.txt"], "license")
    eq(files[PLUGIN .. ".old/_meta.lua"], "meta 1.0.0") -- previous version kept
    eq(dirs[PLUGIN .. ".new"], nil)
    eq(files["/k/plugins/pageframe.koplugin.zip.download"], nil) -- temp zip removed
end)

test("install: a checksum mismatch changes nothing", function()
    local fs, files = installedDisk()
    local transport = goodNet({ [SHA_URL] = { 200, {}, "deadbeef  pageframe.koplugin.zip" } })
    eq({ Update.install(INFO, PLUGIN, { transport = transport, archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs }) },
        { nil, "checksum" })
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
    eq(files["/k/plugins/pageframe.koplugin.zip.download"], nil)
end)

test("install: a missing checksum file (GitHub error) counts as a mismatch", function()
    local fs, files = installedDisk()
    local transport = goodNet({ [SHA_URL] = { 404, {}, "Not Found" } })
    eq(select(2, Update.install(INFO, PLUGIN, { transport = transport, archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "checksum")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
end)

test("install: an empty or failed download is a network error", function()
    local fs, files = installedDisk()
    local transport = goodNet({ ["https://objects.example/zip?sig=1"] = { 200, {}, "" } })
    eq(select(2, Update.install(INFO, PLUGIN, { transport = transport, archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "network")
    eq(select(2, Update.install(INFO, PLUGIN, { transport = net({}), archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "network")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
end)

test("install: a zip entry outside the plugin folder is refused", function()
    local fs, files, dirs = installedDisk()
    local evil = { { "pageframe.koplugin/_meta.lua", "m" }, { "pageframe.koplugin/../../evil.lua", "x" } }
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver(evil), sha256 = sha, fs = fs })),
        "bad_zip")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
    eq(dirs[PLUGIN .. ".new"], nil)
end)

test("install: an unreadable zip is refused", function()
    local fs, files = installedDisk()
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver("corrupt"), sha256 = sha, fs = fs })),
        "bad_zip")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
end)

test("install: a zip without main.lua is incomplete, nothing swapped", function()
    local fs, files, dirs = installedDisk()
    local partial = { { "pageframe.koplugin/_meta.lua", "meta 1.1.0" } }
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver(partial), sha256 = sha, fs = fs })),
        "incomplete")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
    eq(dirs[PLUGIN .. ".new"], nil)
end)

test("install: can't write to the device", function()
    local fs, files = disk({ fail_write = true })
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "write")
end)

test("install: if moving the current version aside fails, it stays in place", function()
    local fs, files = installedDisk()
    fs.rename = (function(orig)
        return function(a, b) if a == PLUGIN then return false end return orig(a, b) end
    end)(fs.rename)
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "swap")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
end)

test("install: if moving the new version in fails, the previous version is put back", function()
    local fs, files, dirs = disk({ fail_rename = function(a) return a == PLUGIN .. ".new" end })
    dirs[PLUGIN] = true
    files[PLUGIN .. "/_meta.lua"] = "meta 1.0.0"
    files[PLUGIN .. "/main.lua"] = "main 1.0.0"
    eq(select(2, Update.install(INFO, PLUGIN, { transport = goodNet(), archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs })),
        "swap")
    eq(files[PLUGIN .. "/_meta.lua"], "meta 1.0.0")
    eq(dirs[PLUGIN .. ".old"], nil)
    eq(dirs[PLUGIN .. ".new"], nil)
end)

test("install: a release without a checksum still installs if the zip is complete", function()
    local fs, files = installedDisk()
    local info = { version = "1.1.0", zip_url = ZIP_URL }
    eq(Update.install(info, PLUGIN, { transport = goodNet(), archiver = archiver(GOOD_ZIP), sha256 = sha, fs = fs }), "1.1.0")
    eq(files[PLUGIN .. "/main.lua"], "main 1.1.0")
end)

-- cleanup ----------------------------------------------------------------------

test("cleanup: removes .old and .new left by an update", function()
    local fs, files, dirs = disk()
    dirs[PLUGIN] = true
    dirs[PLUGIN .. ".old"] = true
    files[PLUGIN .. ".old/main.lua"] = "old"
    dirs[PLUGIN .. ".new"] = true
    Update.cleanup(PLUGIN, fs)
    eq({ dirs[PLUGIN .. ".old"], dirs[PLUGIN .. ".new"], files[PLUGIN .. ".old/main.lua"], dirs[PLUGIN] },
        { nil, nil, nil, true })
end)

H.done()
