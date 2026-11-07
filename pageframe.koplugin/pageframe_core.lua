--[[--
Page Frame: logic that doesn't need KOReader, so it can be tested with plain LuaJIT.

  * inkLevel    turns an image pixel into frame ink (0 = paper, 255 = full ink)
  * listFrames  built-in frames plus image files from the user's frames folder
  * textRect    the largest rectangle that touches none of the frame's drawing
  * margins     pixel insets <-> KOReader's unscaled margin units
  * fontCss     the extra CSS for the font that comes with the frame
--]]

local Core = {}

-- How strongly the artwork is inked, by the Darkness setting.
Core.DARKNESS = { soft = 1.0, normal = 1.6, bold = 2.4 }
Core.DARKNESS_ORDER = { "soft", "normal", "bold" }

-- Ink below this is paper texture or anti-aliasing haze: drop it so the page stays white.
Core.INK_FLOOR = 20
-- A grid cell counts as drawing when some pixel in it is at least this inked.
Core.INK_SOLID = 40

-- Crisp lines: unsharp-mask strength, and a gamma (< 1 deepens mid-tone shading) applied
-- before the S-curve.
Core.SHARPEN = 1.2
Core.CRISP_GAMMA = 0.7

Core.IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, webp = true }

--- Frame ink for one pixel.
-- @int gray 8-bit luminance of the pixel (0 black .. 255 white)
-- @int alpha 8-bit opacity (255 when the image has no alpha)
-- @number k darkness multiplier
-- @treturn int 0..255
function Core.inkLevel(gray, alpha, k)
    local ink = (255 - gray) * alpha / 255 * k
    if ink < Core.INK_FLOOR then return 0 end
    if ink > 255 then return 255 end
    return math.floor(ink)
end

--- Crisp lines: sharpen one pixel of ink against its 3x3 neighbourhood, then an S-curve.
-- Soft scanned or photographed artwork turns grey and blurry on e-ink; this keeps the
-- linework dark and the highlights light, which gives the drawing back its depth.
-- @number ink this pixel's ink (0..255)
-- @number blur average ink of the 3x3 block around it (0..255)
-- @treturn number 0..255
function Core.crisp(ink, blur)
    local v = ink + Core.SHARPEN * (ink - blur)
    if v <= 0 then return 0 end
    if v >= 255 then return 255 end
    local x = (v / 255) ^ Core.CRISP_GAMMA
    return 255 * x * x * (3 - 2 * x)
end

-- Frames ----------------------------------------------------------------------

local function splitName(file)
    local base, ext = file:match("^(.+)%.([^.]+)$")
    if not base then return file, nil end
    return base, ext:lower()
end

--- Built-in frames, then image files from `custom_dir` (sorted by name).
-- @tparam table builtins list of { id, name, path, ... }
-- @string custom_dir folder to scan (may not exist)
-- @tparam table lfs object with attributes(path, "mode") and dir(path)
-- @treturn table list of { id, name, path, builtin = bool, ... }
function Core.listFrames(builtins, custom_dir, lfs)
    local frames = {}
    for _, b in ipairs(builtins) do
        local f = {}
        for k, v in pairs(b) do f[k] = v end
        f.builtin = true
        frames[#frames + 1] = f
    end
    if not custom_dir or lfs.attributes(custom_dir, "mode") ~= "directory" then
        return frames
    end
    local custom, base_count = {}, {}
    for file in lfs.dir(custom_dir) do
        if file:sub(1, 1) ~= "." then
            local base, ext = splitName(file)
            if ext and Core.IMAGE_EXTENSIONS[ext] then
                custom[#custom + 1] = { file = file, base = base }
                base_count[base] = (base_count[base] or 0) + 1
            end
        end
    end
    table.sort(custom, function(a, b)
        local la, lb = a.file:lower(), b.file:lower()
        if la == lb then return a.file < b.file end
        return la < lb
    end)
    for _, c in ipairs(custom) do
        frames[#frames + 1] = {
            id = "custom:" .. c.file,
            -- Show the extension only when two files share a name.
            name = base_count[c.base] > 1 and c.file or c.base,
            path = custom_dir .. "/" .. c.file,
            builtin = false,
        }
    end
    return frames
end

function Core.findFrame(frames, id)
    if not id then return nil end
    for _, f in ipairs(frames) do
        if f.id == id then return f end
    end
    return nil
end

-- Text rectangle ---------------------------------------------------------------

local function isSet(grid, i)
    local v = grid[i]
    return v ~= nil and v ~= false and v ~= 0
end

-- Inked cells minus specks: 8-connected groups of `speck` cells or fewer are dropped.
-- Returns the kept cells (set) and the dropped speck cells (list).
local function inkedWithoutSpecks(grid, gw, gh, speck)
    local inked, specks = {}, {}
    for i = 0, gw * gh - 1 do
        if isSet(grid, i) then inked[i] = true end
    end
    if speck <= 0 then return inked, specks end
    local seen = {}
    for i in pairs(inked) do
        if not seen[i] then
            seen[i] = true
            local group, stack = {}, { i }
            while #stack > 0 do
                local c = table.remove(stack)
                group[#group + 1] = c
                local cx, cy = c % gw, math.floor(c / gw)
                for y = math.max(0, cy - 1), math.min(gh - 1, cy + 1) do
                    for x = math.max(0, cx - 1), math.min(gw - 1, cx + 1) do
                        local n = y * gw + x
                        if inked[n] and not seen[n] then
                            seen[n] = true
                            stack[#stack + 1] = n
                        end
                    end
                end
            end
            if #group <= speck then
                for _, c in ipairs(group) do
                    inked[c] = nil
                    specks[#specks + 1] = c
                end
            end
        end
    end
    table.sort(specks)
    return inked, specks
end

--- The largest rectangle with no drawing in it (and a gap around the drawing).
-- @tparam table grid cell -> inked, indexed y * gw + x from 0 (Lua table or FFI array)
-- @int gw grid width in cells
-- @int gh grid height in cells
-- @tparam table opts
--   cell   pixels per cell (default 8)
--   gap    cells of clearance around drawing (default 3)
--   speck  drop ink groups of this many cells or fewer (default 2)
--   min_w  only rectangles at least this many cells wide (default 0)
--   area_w, area_h  frame area in pixels (default gw * cell, gh * cell)
--   insets optional { l, t, r, b } fractions of the area, used instead of detection
-- @treturn table|nil { l, t, r, b } insets in pixels, or nil when there's too little room
-- @treturn table list of ignored speck cells (indices), so the caller can erase them
function Core.textRect(grid, gw, gh, opts)
    opts = opts or {}
    local cell = opts.cell or 8
    local area_w, area_h = opts.area_w or gw * cell, opts.area_h or gh * cell
    if opts.insets then
        local f = opts.insets
        return {
            math.floor(f[1] * area_w + 0.5), math.floor(f[2] * area_h + 0.5),
            math.floor(f[3] * area_w + 0.5), math.floor(f[4] * area_h + 0.5),
        }
    end
    local gap, min_w = opts.gap or 3, opts.min_w or 0

    local inked, specks = inkedWithoutSpecks(grid, gw, gh, opts.speck or 2)
    local blocked = {}
    for i in pairs(inked) do
        local cx, cy = i % gw, math.floor(i / gw)
        for y = math.max(0, cy - gap), math.min(gh - 1, cy + gap) do
            for x = math.max(0, cx - gap), math.min(gw - 1, cx + gap) do
                blocked[y * gw + x] = true
            end
        end
    end

    -- Largest rectangle in a histogram, row by row.
    local heights, best = {}, nil
    for x = 0, gw - 1 do heights[x] = 0 end
    for y = 0, gh - 1 do
        for x = 0, gw - 1 do
            heights[x] = blocked[y * gw + x] and 0 or heights[x] + 1
        end
        local stack = {}
        for x = 0, gw do
            local h = x < gw and heights[x] or 0
            local start = x
            while #stack > 0 and stack[#stack].h >= h do
                local s = table.remove(stack)
                local w = x - s.x
                if s.h > 0 and w >= min_w then
                    local area = w * s.h
                    if not best or area > best.area then
                        best = { area = area, x = s.x, y = y - s.h + 1, w = w, h = s.h }
                    end
                end
                start = s.x
            end
            stack[#stack + 1] = { x = start, h = h }
        end
    end
    if not best or best.w < gw * 0.4 or best.h < gh * 0.3 then
        return nil, specks
    end
    return {
        best.x * cell,
        best.y * cell,
        math.max(0, area_w - (best.x + best.w) * cell),
        math.max(0, area_h - (best.y + best.h) * cell),
    }, specks
end

--- Speck cells that touch the text rectangle: these get erased from the drawing, so a stray
-- dot in the artwork never lands in the middle of the text.
-- @treturn table list of { x, y, w, h } pixel boxes
function Core.specksInside(specks, gw, insets, area_w, area_h, cell)
    cell = cell or 8
    local boxes = {}
    if not insets then return boxes end
    local x0, y0 = insets[1], insets[2]
    local x1, y1 = area_w - insets[3], area_h - insets[4]
    for _, c in ipairs(specks or {}) do
        local bx, by = (c % gw) * cell, math.floor(c / gw) * cell
        if bx < x1 and bx + cell > x0 and by < y1 and by + cell > y0 then
            boxes[#boxes + 1] = { bx, by, math.min(cell, area_w - bx), math.min(cell, area_h - by) }
        end
    end
    return boxes
end

-- Margins ----------------------------------------------------------------------

--- Smallest unscaled margin that KOReader scales to at least `px` pixels.
-- KOReader scales with ceil(v * ratio), where ratio = Screen:scaleBySize(1000) / 1000.
function Core.unscale(px, ratio)
    if px <= 0 then return 0 end
    return math.ceil(px / ratio - 1e-9)
end

--- Pixel insets { l, t, r, b } -> unscaled margins { l, t, r, b }.
function Core.marginsFor(insets, ratio)
    return {
        Core.unscale(insets[1], ratio), Core.unscale(insets[2], ratio),
        Core.unscale(insets[3], ratio), Core.unscale(insets[4], ratio),
    }
end

function Core.marginsEqual(a, b)
    if a == nil or b == nil then return a == b end
    for i = 1, 4 do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Font -------------------------------------------------------------------------

Core.DEFAULT_FONT = "Cormorant Garamond"
Core.KEEP_FONT = "keep"

--- Extra CSS for the font that comes with the frame ("" when there is none).
-- @tparam table s settings: font (family name or "keep"), italic (bool)
-- @bool frame_on whether a frame is being shown
function Core.fontCss(s, frame_on)
    if not frame_on then return "" end
    local parts = {}
    local font = s.font
    if font and font ~= Core.KEEP_FONT then
        font = font:gsub('"', "")
        if font ~= "" then
            parts[#parts + 1] = 'body { font-family: "' .. font .. '" !important; }'
            parts[#parts + 1] = "body * { font-family: inherit !important; }"
            parts[#parts + 1] = "listing, plaintext, xmp, samp, tt, kbd, pre, code { font-family: monospace !important; }"
        end
    end
    if s.italic then
        parts[#parts + 1] = "body, body * { font-style: italic !important; }"
        -- Emphasis turns upright, so it still stands out in italic text.
        parts[#parts + 1] = "em, i, cite, dfn, var, em *, i *, cite * { font-style: normal !important; }"
    end
    return table.concat(parts, "\n")
end

return Core
