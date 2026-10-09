-- Blossom's updater: pure helpers and the install flow with a fake disk and network.
local H = require("tests.harness")
local test, eq = H.test, H.eq
local Update = require("blossom_update")

test("version compare is numeric, segment by segment", function()
    eq(Update.compareVersions("1.10.0", "1.9.2"), 1)
    eq(Update.compareVersions("1.0", "1.0.0"), 0)
    eq(Update.compareVersions("1.0.0", "1.0.1"), -1)
    eq(Update.compareVersions("2", "1.99.99"), 1)
    eq(Update.parseVersion("v1.0"), nil)
    eq(Update.parseVersion("1.2.3"), { 1, 2, 3 })
end)

test("pickRelease: newest of our own tag only, no drafts or prereleases", function()
    local releases = {
        { tag_name = "blossomreads-v9.0.0" },              -- the other plugin
        { tag_name = "blossom-v1.2.0", draft = true },
        { tag_name = "blossom-v1.3.0", prerelease = true },
        { tag_name = "blossom-v1.10.0" },
        { tag_name = "blossom-v1.9.0" },
        { tag_name = "blossom-vX" },
        "junk",
    }
    local r, v = Update.pickRelease(releases, "blossom")
    eq({ r.tag_name, v }, { "blossom-v1.10.0", "1.10.0" })
    eq(select(2, Update.pickRelease(releases, "blossomreads")), "9.0.0")
    eq(Update.pickRelease({}, "blossom"), nil)
    eq(Update.pickRelease(nil, "blossom"), nil)
end)

test("safeEntry keeps zip entries inside the plugin folder", function()
    local root = "blossom.koplugin"
    eq(Update.safeEntry("blossom.koplugin/", root), true)
    eq(Update.safeEntry("blossom.koplugin/main.lua", root), true)
    eq(Update.safeEntry("blossom.koplugin/icons/bow.svg", root), true)
    eq(Update.safeEntry("/etc/passwd", root), false)
    eq(Update.safeEntry("blossom.koplugin/../../x", root), false)
    eq(Update.safeEntry("blossomreads.koplugin/main.lua", root), false)
    eq(Update.safeEntry("blossom.koplugin.evil/main.lua", root), false)
    eq(Update.safeEntry("C:/x", root), false)
    eq(Update.safeEntry("blossom.koplugin\\..\\x", root), false)
    eq(Update.safeEntry("", root), false)
end)

test("parseChecksum reads sha256sum output", function()
    local hex = string.rep("ab", 32)
    eq(Update.parseChecksum(hex .. "  blossom.koplugin.zip\n"), hex)
    eq(Update.parseChecksum(hex:upper()), hex)
    eq(Update.parseChecksum("nope"), nil)
    eq(Update.parseChecksum(nil), nil)
end)

test("check: newer, same, none, network error", function()
    local function io(rel) return { getJSON = function() return rel end } end
    local r = Update.check(io({ { tag_name = "blossom-v1.1.0" } }), "blossom", "1.0.0")
    eq({ r.newer, r.version }, { true, "1.1.0" })
    eq(Update.check(io({ { tag_name = "blossom-v1.0.0" } }), "blossom", "1.0.0").newer, false)
    eq(Update.check(io({}), "blossom", "1.0.0"), { newer = false, version = "1.0.0" })
    local res, err = Update.check({ getJSON = function() return nil, "http 403" end }, "blossom", "1.0.0")
    eq({ res, err }, { nil, "http 403" })
end)

-- A fake disk: paths -> "dir" or file contents. Folders move with everything under them.
local function fakeDisk(files)
    local disk = { files = files or {}, log = {} }
    local function under(prefix, path) return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" end
    local io = {}
    function io.mkdir(p) disk.files[p] = disk.files[p] or "dir" end
    function io.exists(p) return disk.files[p] ~= nil end
    function io.readFile(p) local v = disk.files[p]; return v ~= "dir" and v or nil end
    function io.sha256(data) return data == "ZIPBYTES" and string.rep("cd", 32) or string.rep("00", 32) end
    function io.purge(p)
        for k in pairs(disk.files) do if under(p, k) then disk.files[k] = nil end end
    end
    function io.rename(from, to)
        table.insert(disk.log, from .. " -> " .. to)
        if disk.fail_rename and disk.fail_rename(from, to) then return nil, "busy" end
        if not disk.files[from] then return nil, "missing" end
        local moved = {}
        for k, v in pairs(disk.files) do if under(from, k) then moved[to .. k:sub(#from + 1)] = v; disk.files[k] = nil end end
        for k, v in pairs(moved) do disk.files[k] = v end
        return true
    end
    function io.download(url, dest)
        if disk.net[url] == nil then return nil, "404" end
        disk.files[dest] = disk.net[url]
        return true
    end
    function io.unzip(zip, dest, keep)
        local entries = disk.zips[disk.files[zip]]
        if not entries then return nil, "bad zip" end
        for path in pairs(entries) do if not keep(path) then return nil, "unsafe " .. path end end
        for path, content in pairs(entries) do disk.files[dest .. "/" .. path:gsub("/$", "")] = content end
        return true
    end
    disk.io = io
    return disk
end

local PLUGINS = "/kindle/koreader/plugins"
local DIR = PLUGINS .. "/blossom.koplugin"
local hex = string.rep("cd", 32)

local function release(with_sum)
    local assets = { { name = "blossom.koplugin.zip", browser_download_url = "https://gh/zip" } }
    if with_sum then assets[2] = { name = "blossom.koplugin.zip.sha256", browser_download_url = "https://gh/sum" } end
    return { tag_name = "blossom-v1.1.0", assets = assets }
end

local function setup(zip_entries)
    local disk = fakeDisk({ [DIR] = "dir", [DIR .. "/main.lua"] = "old main", [DIR .. "/_meta.lua"] = "old meta" })
    disk.net = { ["https://gh/zip"] = "ZIPBYTES", ["https://gh/sum"] = string.rep("cd", 32) .. "  blossom.koplugin.zip\n" }
    disk.zips = { ZIPBYTES = zip_entries or {
        ["blossom.koplugin/"] = "dir",
        ["blossom.koplugin/main.lua"] = "new main",
        ["blossom.koplugin/_meta.lua"] = "new meta",
        ["blossom.koplugin/icons/bow.svg"] = "<svg/>",
    } }
    return disk
end

local function install(disk, rel)
    return Update.install(disk.io, { name = "blossom.koplugin", plugin_dir = DIR, work_dir = "/kindle/koreader/settings/blossom/update",
        release = rel or release(true), version = "1.1.0" })
end

test("install: download, verify, unpack, swap", function()
    local disk = setup()
    eq(install(disk), true)
    eq(disk.files[DIR .. "/main.lua"], "new main")
    eq(disk.files[DIR .. "/icons/bow.svg"], "<svg/>")
    eq(disk.files[PLUGINS .. "/blossom.koplugin.old/main.lua"], "old main") -- backup until next start
    eq(disk.files[PLUGINS .. "/blossom.koplugin.new"], nil)                 -- staging cleaned
    Update.cleanup(disk.io, DIR, "blossom.koplugin")
    eq(disk.files[PLUGINS .. "/blossom.koplugin.old/main.lua"], nil)
    eq(disk.files[DIR .. "/main.lua"], "new main")
end)

test("install without a checksum asset still works", function()
    local disk = setup()
    eq(install(disk, release(false)), true)
end)

test("install refuses: no asset, download error, bad checksum — plugin untouched", function()
    local disk = setup()
    eq({ install(disk, { tag_name = "blossom-v1.1.0", assets = {} }) }, { nil, "no_asset" })
    disk.net["https://gh/zip"] = nil
    eq(select(2, install(disk)), "download")
    disk = setup()
    disk.net["https://gh/sum"] = string.rep("ef", 32) .. "  blossom.koplugin.zip"
    eq(select(2, install(disk)), "checksum")
    eq(disk.files[DIR .. "/main.lua"], "old main")
end)

test("install refuses a zip that isn't a whole plugin, or has unsafe paths", function()
    local disk = setup({ ["blossom.koplugin/main.lua"] = "x" })           -- no _meta.lua
    eq(select(2, install(disk)), "bad_zip")
    eq(disk.files[DIR .. "/main.lua"], "old main")
    eq(disk.files[PLUGINS .. "/blossom.koplugin.new"], nil)
    disk = setup({ ["blossom.koplugin/main.lua"] = "x", ["blossom.koplugin/_meta.lua"] = "m", ["../../evil.sh"] = "x" })
    eq(select(2, install(disk)), "bad_zip")
    eq(disk.files[DIR .. "/main.lua"], "old main")
end)

test("a failed swap puts the old plugin back", function()
    local disk = setup()
    disk.fail_rename = function(from) return from:find("%.new/blossom%.koplugin$") ~= nil end
    eq(select(2, install(disk)), "swap")
    eq(disk.files[DIR .. "/main.lua"], "old main")
    eq(disk.files[PLUGINS .. "/blossom.koplugin.old"], nil)
    eq(disk.files[PLUGINS .. "/blossom.koplugin.new"], nil)
end)

test("a read-only plugin folder is reported and nothing changes", function()
    local disk = setup()
    disk.fail_rename = function(from) return from == DIR end
    eq(select(2, install(disk)), "not_writable")
    eq(disk.files[DIR .. "/main.lua"], "old main")
end)

H.done()
