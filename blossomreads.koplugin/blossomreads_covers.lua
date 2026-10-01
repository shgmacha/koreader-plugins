--[[--
Small on-disk cache of Goodreads cover pictures (settings/blossomreads/covers).

Only the covers on the page being shown are fetched, at most MAX files are
kept (oldest removed first), and ImageWidget decodes them from the file so no
blitbuffers are held by this module.
--]]

local Http = require("blossomreads_http")
local Store = require("blossomreads_store")

local Covers = {}

Covers.MAX = 60
Covers.MAX_BYTES = 400 * 1024

function Covers.dir()
    return Store.dir() .. "/covers"
end

function Covers.path(gid)
    return Covers.dir() .. "/" .. tostring(gid):gsub("[^%w]", "") .. ".jpg"
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- The cover's file if it was downloaded before (never goes online).
function Covers.cached(gid)
    local path = gid and Covers.path(gid)
    return path and exists(path) and path or nil
end

-- Returns the cover's file, downloading it once. nil when there is none.
function Covers.get(gid, url, transport)
    if not gid then return nil end
    local path = Covers.path(gid)
    if exists(path) then return path end
    if not url or url == "" or url:find("nophoto", 1, true) then return nil end
    local r = Http.new{ transport = transport }:get(url)
    if r.err or not r.body or #r.body < 100 or #r.body > Covers.MAX_BYTES then return nil end
    Store.ensureDir(Covers.dir())
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(r.body)
    f:close()
    Covers.prune()
    return path
end

-- Keep the newest MAX covers.
function Covers.prune(lfs)
    local ok, fs = pcall(require, "libs/libkoreader-lfs")
    lfs = lfs or (ok and fs) or nil
    if not (lfs and lfs.dir) then return end
    local files = {}
    local okdir, iter, state = pcall(lfs.dir, Covers.dir())
    if not okdir then return end
    for name in iter, state do
        if name:match("%.jpg$") then
            local p = Covers.dir() .. "/" .. name
            files[#files + 1] = { p = p, t = lfs.attributes(p, "modification") or 0 }
        end
    end
    if #files <= Covers.MAX then return end
    table.sort(files, function(a, b) return a.t < b.t end)
    for i = 1, #files - Covers.MAX do os.remove(files[i].p) end
end

return Covers
