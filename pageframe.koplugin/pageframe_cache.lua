--[[--
Page Frame's disk cache of prepared frames (koreader/cache/pageframe/).

Preparing a frame (decode, ink mask, crisp lines, text rectangle) takes about 1.4 s on a
Paperwhite 5, so the result is saved and loaded on the next book open instead.

One file per prepared frame, named md5(key).pfm:
    PFM1 <tab> key <tab> w <tab> h <tab> l,t,r,b | none <newline>
    w*h raw mask bytes, row by row

A file is only used when the magic, the whole key, the size and the body length all match;
anything else is deleted and rebuilt, never drawn. Files are written to .tmp and then renamed,
so a reset mid-write can't leave a half file under the real name.
--]]

local ffi = require("ffi")

local Cache = {}

Cache.MAGIC = "PFM1"
Cache.EXT = ".pfm"
Cache.KEEP = 6

Cache.fs = {
    open = function(p, mode) return io.open(p, mode) end,
    rename = function(a, b) return os.rename(a, b) end,
    remove = function(p) return os.remove(p) end,
    mkdir = function(p)
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs then
            local parent = p:match("^(.*)/[^/]+$")
            if parent and lfs.attributes(parent, "mode") ~= "directory" then lfs.mkdir(parent) end
            if lfs.attributes(p, "mode") ~= "directory" then lfs.mkdir(p) end
        else
            os.execute("mkdir -p '" .. p:gsub("'", "'\\''") .. "'")
        end
    end,
    list = function(dir)
        local names = {}
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs and lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do names[#names + 1] = name end
        end
        return names
    end,
    mtime = function(p)
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        return ok and lfs and lfs.attributes(p, "modification") or 0
    end,
}

-- A short, file-name-safe hash of the key.
function Cache.name(key)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then return sha2.md5(key) .. Cache.EXT end
    local h1, h2 = 5381, 52711
    for i = 1, #key do
        local c = key:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c) % 4294967296
    end
    return string.format("%08x%08x", h1, h2) .. Cache.EXT
end

local function insetsText(insets)
    if not insets then return "none" end
    return table.concat({ insets[1], insets[2], insets[3], insets[4] }, ",")
end

local function parseInsets(text)
    if text == "none" then return nil, true end
    local l, t, r, b = text:match("^(%d+),(%d+),(%d+),(%d+)$")
    if not l then return nil, false end
    return { tonumber(l), tonumber(t), tonumber(r), tonumber(b) }, true
end

--- Load a prepared frame.
-- @string dir cache folder
-- @string key Core.cacheKey(...)
-- @int w, h expected size
-- @tparam function new_mask (w, h) -> BB8 mask (with .data and .stride)
-- @treturn mask, insets (insets may be nil) | nil when missing or invalid (invalid files are deleted)
function Cache.load(dir, key, w, h, new_mask, fs)
    fs = fs or Cache.fs
    local path = dir .. "/" .. Cache.name(key)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local header = f:read("*l") or ""
    local magic, hkey, hw, hh, hins = header:match("^(%w+)\t([^\t]*)\t(%d+)\t(%d+)\t([^\t]*)$")
    local insets, insets_ok
    if hins then insets, insets_ok = parseInsets(hins) end
    local body
    if magic == Cache.MAGIC and hkey == key and tonumber(hw) == w and tonumber(hh) == h and insets_ok then
        body = f:read(w * h)
        if body and #body == w * h and f:read(1) ~= nil then body = nil end -- trailing bytes
    end
    f:close()
    if not body or #body ~= w * h then
        fs.remove(path)
        return nil
    end
    local mask = new_mask(w, h)
    local dst = ffi.cast("uint8_t *", mask.data)
    local stride = tonumber(mask.stride)
    if stride == w then
        ffi.copy(dst, body, w * h)
    else
        local src = ffi.cast("const uint8_t *", body)
        for y = 0, h - 1 do
            ffi.copy(dst + y * stride, src + y * w, w)
        end
    end
    return mask, insets
end

--- Save a prepared frame. Never raises; returns true when the file is in place.
function Cache.save(dir, key, w, h, mask, insets, fs)
    fs = fs or Cache.fs
    fs.mkdir(dir)
    local path = dir .. "/" .. Cache.name(key)
    local tmp = path .. ".tmp"
    local f = fs.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(table.concat({ Cache.MAGIC, key, w, h, insetsText(insets) }, "\t") .. "\n")
    local src = ffi.cast("const uint8_t *", mask.data)
    local stride = tonumber(mask.stride)
    if ok then
        if stride == w then
            ok = f:write(ffi.string(src, w * h))
        else
            for y = 0, h - 1 do
                ok = f:write(ffi.string(src + y * stride, w))
                if not ok then break end
            end
        end
    end
    local closed = f:close()
    if not ok or closed == false then
        fs.remove(tmp)
        return false
    end
    if not fs.rename(tmp, path) then
        fs.remove(path) -- some filesystems won't rename over an existing file
        if not fs.rename(tmp, path) then
            fs.remove(tmp)
            return false
        end
    end
    return true
end

--- Keep the `keep` most recently written frames; remove leftover .tmp files.
function Cache.trim(dir, keep, fs)
    fs = fs or Cache.fs
    keep = keep or Cache.KEEP
    local frames = {}
    for _, name in ipairs(fs.list(dir)) do
        local path = dir .. "/" .. name
        if name:sub(-4) == ".tmp" then
            fs.remove(path)
        elseif name:sub(-#Cache.EXT) == Cache.EXT then
            frames[#frames + 1] = { path = path, mtime = fs.mtime(path) or 0, name = name }
        end
    end
    table.sort(frames, function(a, b)
        if a.mtime == b.mtime then return a.name < b.name end
        return a.mtime > b.mtime
    end)
    for i = keep + 1, #frames do fs.remove(frames[i].path) end
end

return Cache
