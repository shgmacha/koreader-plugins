-- Page Frame's disk cache: round trip, validation, atomic save, trim. In-memory disk.
local H = require("tests.harness")
package.path = "./pageframe.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
local Cache = require("pageframe_cache")
local test, eq = H.test, H.eq

-- In-memory disk with Lua-file-like handles ------------------------------------
local function disk(opts)
    opts = opts or {}
    local files, mtimes, clock = {}, {}, 0
    local fs = {}
    function fs.open(path, mode)
        if mode:sub(1, 1) == "r" then
            local data = files[path]
            if not data then return nil end
            local pos = 1
            return {
                read = function(_, what)
                    if pos > #data then return nil end
                    if what == "*l" then
                        local nl = data:find("\n", pos, true)
                        local line = data:sub(pos, (nl or #data + 1) - 1)
                        pos = (nl or #data) + 1
                        return line
                    end
                    local chunk = data:sub(pos, pos + what - 1)
                    pos = pos + #chunk
                    return chunk
                end,
                close = function() return true end,
            }
        end
        if opts.no_open then return nil end
        local parts, writes = {}, 0
        return {
            write = function(_, s)
                writes = writes + 1
                if opts.fail_write_at and writes >= opts.fail_write_at then return nil end
                parts[#parts + 1] = s
                return true
            end,
            close = function()
                clock = clock + 1
                files[path] = table.concat(parts)
                mtimes[path] = clock
                return true
            end,
        }
    end
    function fs.rename(a, b)
        if opts.fail_rename then return false end
        if not files[a] then return false end
        if opts.no_overwrite and files[b] then return false end -- like some FAT drivers
        files[b], files[a] = files[a], nil
        mtimes[b], mtimes[a] = mtimes[a], nil
        return true
    end
    function fs.remove(p) files[p], mtimes[p] = nil, nil; return true end
    function fs.mkdir(p) fs.made = p end
    function fs.list(dir)
        local out = {}
        for p in pairs(files) do
            local name = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+)$")
            if name then out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end
    function fs.mtime(p) return mtimes[p] end
    return fs, files
end

-- A BB8-like mask, optionally with padding at the end of each row.
local function newMask(w, h, stride)
    stride = stride or w
    return { w = w, h = h, stride = stride, data = ffi.new("uint8_t[?]", stride * h) }
end

local function pattern(mask)
    for y = 0, mask.h - 1 do
        for x = 0, mask.w - 1 do mask.data[y * mask.stride + x] = (x * 7 + y * 13) % 256 end
    end
    return mask
end

local function sameMask(a, b)
    for y = 0, a.h - 1 do
        for x = 0, a.w - 1 do
            if a.data[y * a.stride + x] ~= b.data[y * b.stride + x] then return false end
        end
    end
    return true
end

local DIR = "/k/cache/pageframe"
local KEY = "1|/k/frames/Rose garland.webp|417772|1794120000|30x20|soft|true|8"
local INSETS = { 8, 16, 8, 0 }

-- Round trips -------------------------------------------------------------------

test("save then load gives the same mask and insets", function()
    local fs, files = disk()
    local mask = pattern(newMask(30, 20))
    eq(Cache.save(DIR, KEY, 30, 20, mask, INSETS, fs), true)
    eq(fs.made, DIR)
    local path = DIR .. "/" .. Cache.name(KEY)
    assert(files[path], "file under its hashed name")
    eq(#files[path] > 600, true)
    local loaded, insets = Cache.load(DIR, KEY, 30, 20, newMask, fs)
    eq(sameMask(mask, loaded), true)
    eq(insets, INSETS)
end)

test("masks whose rows are padded (stride > width) round-trip both ways", function()
    local fs = disk()
    local mask = pattern(newMask(30, 20, 32))
    eq(Cache.save(DIR, KEY, 30, 20, mask, INSETS, fs), true)
    local loaded = Cache.load(DIR, KEY, 30, 20, function(w, h) return newMask(w, h, 40) end, fs)
    eq(sameMask(mask, loaded), true)
end)

test("a frame with no room for text (no insets) round-trips as none", function()
    local fs = disk()
    eq(Cache.save(DIR, KEY, 30, 20, pattern(newMask(30, 20)), nil, fs), true)
    local loaded, insets = Cache.load(DIR, KEY, 30, 20, newMask, fs)
    assert(loaded)
    eq(insets, nil)
end)

test("a missing file is a miss", function()
    local fs = disk()
    eq(Cache.load(DIR, KEY, 30, 20, newMask, fs), nil)
end)

-- Validation: bad files are deleted, never used ----------------------------------

local function savedFile()
    local fs, files = disk()
    Cache.save(DIR, KEY, 30, 20, pattern(newMask(30, 20)), INSETS, fs)
    return fs, files, DIR .. "/" .. Cache.name(KEY)
end

local function rejects(mutate)
    local fs, files, path = savedFile()
    files[path] = mutate(files[path])
    eq(Cache.load(DIR, KEY, 30, 20, newMask, fs), nil)
    eq(files[path], nil) -- deleted
end

test("rejects a wrong magic", function()
    rejects(function(d) return (d:gsub("^PFM1", "PFM9")) end)
end)

test("rejects a file written for another key (collision or stale)", function()
    rejects(function(d) return (d:gsub("|soft|", "|bold|", 1)) end)
end)

test("rejects a different size", function()
    rejects(function(d) return (d:gsub("\t30\t20\t", "\t31\t20\t", 1)) end)
end)

test("rejects a truncated body", function()
    rejects(function(d) return d:sub(1, -2) end)
end)

test("rejects trailing bytes", function()
    rejects(function(d) return d .. "x" end)
end)

test("rejects garbage and an empty file", function()
    rejects(function() return "\0\0\0 not a frame" end)
    rejects(function() return "" end)
end)

test("rejects malformed insets", function()
    rejects(function(d) return (d:gsub("\t8,16,8,0\n", "\t8,16,x\n", 1)) end)
end)

test("asking with the wrong size rejects (and deletes) the file", function()
    local fs, files, path = savedFile()
    eq(Cache.load(DIR, KEY, 30, 21, newMask, fs), nil)
    eq(files[path], nil)
end)

-- Saving safely ------------------------------------------------------------------

test("a failed write leaves no frame file and no .tmp", function()
    local fs, files = disk({ fail_write_at = 2 })
    eq(Cache.save(DIR, KEY, 30, 20, pattern(newMask(30, 20)), INSETS, fs), false)
    eq(next(files), nil)
end)

test("a failed rename leaves no frame file and no .tmp", function()
    local fs, files = disk({ fail_rename = true })
    eq(Cache.save(DIR, KEY, 30, 20, pattern(newMask(30, 20)), INSETS, fs), false)
    eq(next(files), nil)
end)

test("an unwritable folder just fails", function()
    local fs = disk({ no_open = true })
    eq(Cache.save(DIR, KEY, 30, 20, pattern(newMask(30, 20)), INSETS, fs), false)
end)

test("saving over an existing file replaces it", function()
    local fs = disk()
    Cache.save(DIR, KEY, 30, 20, newMask(30, 20), INSETS, fs)
    local mask = pattern(newMask(30, 20))
    eq(Cache.save(DIR, KEY, 30, 20, mask, { 1, 2, 3, 4 }, fs), true)
    local loaded, insets = Cache.load(DIR, KEY, 30, 20, newMask, fs)
    eq(sameMask(mask, loaded), true)
    eq(insets, { 1, 2, 3, 4 })
end)

test("saving over an existing file works where rename won't overwrite", function()
    local fs = disk({ no_overwrite = true })
    Cache.save(DIR, KEY, 30, 20, newMask(30, 20), INSETS, fs)
    local mask = pattern(newMask(30, 20))
    eq(Cache.save(DIR, KEY, 30, 20, mask, { 1, 2, 3, 4 }, fs), true)
    local loaded = Cache.load(DIR, KEY, 30, 20, newMask, fs)
    eq(sameMask(mask, loaded), true)
end)

-- Trim ---------------------------------------------------------------------------

test("trim keeps the newest frames and removes .tmp leftovers", function()
    local fs, files = disk()
    local names = {}
    for i = 1, 8 do
        local key = KEY .. "|" .. i
        Cache.save(DIR, key, 30, 20, newMask(30, 20), INSETS, fs)
        names[i] = DIR .. "/" .. Cache.name(key)
    end
    files[DIR .. "/abandoned.pfm.tmp"] = "half"
    files[DIR .. "/notes.txt"] = "not ours"
    Cache.trim(DIR, 6, fs)
    eq({ files[names[1]], files[names[2]] }, {}) -- the two oldest are gone
    for i = 3, 8 do assert(files[names[i]], "kept " .. i) end
    eq(files[DIR .. "/abandoned.pfm.tmp"], nil)
    eq(files[DIR .. "/notes.txt"], "not ours")
end)

test("name is stable, different per key, and file-name safe", function()
    eq(Cache.name(KEY), Cache.name(KEY))
    assert(Cache.name(KEY) ~= Cache.name(KEY .. "x"))
    assert(Cache.name(KEY):match("^[%x]+%.pfm$"), Cache.name(KEY))
end)

H.done()
