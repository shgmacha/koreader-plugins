-- Page Frame core logic: ink levels, frame listing, the text rectangle, margins, font CSS.
local H = require("tests.harness")
package.path = "./pageframe.koplugin/?.lua;" .. package.path
local Core = require("pageframe_core")
local test, eq = H.test, H.eq

-- inkLevel ---------------------------------------------------------------------

test("inkLevel: a transparent pixel is paper, whatever its colour", function()
    eq(Core.inkLevel(0, 0, 2.4), 0)
end)

test("inkLevel: opaque black is full ink", function()
    eq(Core.inkLevel(0, 255, 1.0), 255)
end)

test("inkLevel: mid grey is scaled by the darkness", function()
    eq(Core.inkLevel(128, 255, 1.0), 127)
    eq(Core.inkLevel(128, 255, 1.6), 203)
end)

test("inkLevel: capped at 255", function()
    eq(Core.inkLevel(50, 255, 2.4), 255)
end)

test("inkLevel: faint haze below the floor is dropped", function()
    eq(Core.inkLevel(240, 255, 1.0), 0) -- 15 < 20
    eq(Core.inkLevel(230, 255, 1.0), 25)
end)

test("inkLevel: half-transparent ink is half as dark", function()
    eq(Core.inkLevel(0, 128, 1.0), 128)
end)

-- crisp ------------------------------------------------------------------------

test("crisp: paper stays paper and full ink stays full", function()
    eq(Core.crisp(0, 0), 0)
    eq(Core.crisp(255, 255), 255)
end)

test("crisp: never leaves 0..255, even at hard edges", function()
    eq(Core.crisp(255, 0), 255)   -- ink pixel next to paper: overshoot clamped
    eq(Core.crisp(0, 255), 0)     -- paper pixel next to ink: undershoot clamped
end)

test("crisp: on flat areas it only applies the tone curve, which keeps order", function()
    local last = -1
    for v = 0, 255, 5 do
        local c = Core.crisp(v, v)
        assert(c >= last, "tone curve must not decrease at " .. v)
        last = c
    end
end)

test("crisp: mid-tone shading gets deeper, faint haze stays faint", function()
    assert(Core.crisp(128, 128) > 150, "mid tone should deepen: " .. Core.crisp(128, 128))
    assert(Core.crisp(15, 15) < 25, "haze should stay faint: " .. Core.crisp(15, 15))
end)

test("crisp: a line darker than its surroundings gets darker still", function()
    assert(Core.crisp(120, 60) > Core.crisp(120, 120))
    assert(Core.crisp(60, 120) < Core.crisp(60, 60))
end)

-- listFrames -------------------------------------------------------------------

local function fakeLfs(dirs)
    return {
        attributes = function(path, what)
            assert(what == "mode")
            return dirs[path] and "directory" or nil
        end,
        dir = function(path)
            local files, i = { ".", ".." }, 0
            for _, f in ipairs(dirs[path]) do files[#files + 1] = f end
            return function() i = i + 1; return files[i] end
        end,
    }
end

local BUILTINS = { { id = "builtin:rose-garland", name = "Rose garland", path = "/p/frames/rose-garland.webp" } }

local function ids(frames)
    local out = {}
    for i, f in ipairs(frames) do out[i] = f.id end
    return out
end

test("listFrames: no frames folder gives the built-ins only", function()
    local frames = Core.listFrames(BUILTINS, "/data/frames", fakeLfs({}))
    eq(ids(frames), { "builtin:rose-garland" })
    eq(frames[1].builtin, true)
end)

test("listFrames: built-in entries are copied, not shared", function()
    local frames = Core.listFrames(BUILTINS, nil, fakeLfs({}))
    frames[1].name = "changed"
    eq(BUILTINS[1].name, "Rose garland")
end)

test("listFrames: only images, any case, hidden files skipped, sorted", function()
    local lfs = fakeLfs({ ["/data/frames"] = {
        "zebra.PNG", "notes.txt", ".hidden.png", "Apple.jpeg", "moon.webp", "README", "leaf.JPG", "x.gif",
    } })
    local frames = Core.listFrames(BUILTINS, "/data/frames", lfs)
    eq(ids(frames), {
        "builtin:rose-garland", "custom:Apple.jpeg", "custom:leaf.JPG", "custom:moon.webp", "custom:zebra.PNG",
    })
    eq(frames[2].name, "Apple")
    eq(frames[2].path, "/data/frames/Apple.jpeg")
    eq(frames[2].builtin, false)
end)

test("listFrames: two files with the same name keep their extensions apart", function()
    local lfs = fakeLfs({ ["/data/frames"] = { "lace.png", "lace.webp", "ivy.png" } })
    local frames = Core.listFrames({}, "/data/frames", lfs)
    eq(ids(frames), { "custom:ivy.png", "custom:lace.png", "custom:lace.webp" })
    eq({ frames[1].name, frames[2].name, frames[3].name }, { "ivy", "lace.png", "lace.webp" })
end)

test("findFrame: by id, nil when missing", function()
    local frames = Core.listFrames(BUILTINS, nil, fakeLfs({}))
    eq(Core.findFrame(frames, "builtin:rose-garland").name, "Rose garland")
    eq(Core.findFrame(frames, "custom:gone.png"), nil)
    eq(Core.findFrame(frames, nil), nil)
end)

-- textRect ---------------------------------------------------------------------

-- A gw x gh grid with a one-cell border of ink.
local function ring(gw, gh)
    local g = {}
    for x = 0, gw - 1 do g[x] = 1; g[(gh - 1) * gw + x] = 1 end
    for y = 0, gh - 1 do g[y * gw] = 1; g[y * gw + gw - 1] = 1 end
    return g
end

test("textRect: empty grid gives the whole area", function()
    eq(Core.textRect({}, 20, 30, { gap = 2 }), { 0, 0, 0, 0 })
end)

test("textRect: a ring frame gives its inside, minus the gap", function()
    -- border cell + 2 gap cells = 3 cells = 24 px on each side
    eq(Core.textRect(ring(20, 30), 20, 30, { gap = 2 }), { 24, 24, 24, 24 })
end)

test("textRect: works with an FFI-style grid of zeros and ones", function()
    local ffi = require("ffi")
    local gw, gh = 20, 30
    local g = ffi.new("uint8_t[?]", gw * gh)
    for i, v in pairs(ring(gw, gh)) do g[i] = v end
    eq(Core.textRect(g, gw, gh, { gap = 2 }), { 24, 24, 24, 24 })
end)

test("textRect: specks of one or two cells are ignored", function()
    local g = ring(20, 30)
    g[15 * 20 + 10] = 1
    g[15 * 20 + 11] = 1
    eq(Core.textRect(g, 20, 30, { gap = 2 }), { 24, 24, 24, 24 })
end)

test("textRect: a three-cell blob is drawing, not a speck", function()
    local g = ring(20, 30)
    g[15 * 20 + 10] = 1; g[15 * 20 + 11] = 1; g[16 * 20 + 11] = 1
    local r = Core.textRect(g, 20, 30, { gap = 2 })
    assert(r, "expected a rectangle")
    -- The rectangle must avoid the blob and its gap: rows 13..18, columns 8..13 are blocked.
    local x0, y0 = r[1] / 8, r[2] / 8
    local x1, y1 = 20 - r[3] / 8 - 1, 30 - r[4] / 8 - 1
    local overlaps = not (x1 < 8 or x0 > 13 or y1 < 13 or y0 > 18)
    eq(overlaps, false)
end)

test("textRect: speck = 0 keeps every dot", function()
    local g = ring(20, 30)
    g[15 * 20 + 10] = 1
    local r = Core.textRect(g, 20, 30, { gap = 2, speck = 0 })
    assert(r)
    eq(r[1] == 24 and r[2] == 24 and r[3] == 24 and r[4] == 24, false)
end)

-- Ring plus a bouquet filling the bottom-left 8x10 cells.
local function bouquet()
    local gw, gh = 40, 60
    local g = ring(gw, gh)
    for y = gh - 10, gh - 1 do for x = 0, 7 do g[y * gw + x] = 1 end end
    return g, gw, gh
end

test("textRect: a corner bouquet picks the larger free rectangle", function()
    local g, gw, gh = bouquet()
    -- Bouquet + gap blocks columns 0..9 from row 48 down.
    -- Tall option: x 10..36 (27 wide) x y 3..56 (54 tall) = 1458 cells.
    -- Wide option: x 3..36 (34 wide) x y 3..47 (45 tall) = 1530 cells. Wide wins.
    eq(Core.textRect(g, gw, gh, { gap = 2 }), { 24, 24, 24, 96 })
end)

test("textRect: without min_w a tall shape can win; min_w forces the wide one", function()
    local g, gw, gh = bouquet()
    -- Make the wide option shorter: the bouquet now reaches row 30 (blocked from row 28).
    for y = 30, gh - 1 do for x = 0, 7 do g[y * gw + x] = 1 end end
    -- Tall: x 10..36 (27) x y 3..56 (54) = 1458; wide: x 3..36 (34) x y 3..27 (25) = 850.
    eq(Core.textRect(g, gw, gh, { gap = 2 }), { 80, 24, 24, 24 })
    eq(Core.textRect(g, gw, gh, { gap = 2, min_w = 30 }), { 24, 24, 24, 32 * 8 })
end)

test("textRect: min_w wider than anything possible gives nil", function()
    local g, gw, gh = bouquet()
    -- With the tall shape forbidden by width, the result is the wide one (also the default here),
    -- and a min_w wider than anything possible gives nil.
    eq(Core.textRect(g, gw, gh, { gap = 2, min_w = 30 }), { 24, 24, 24, 96 })
    eq(Core.textRect(g, gw, gh, { gap = 2, min_w = 39 }), nil)
end)

test("textRect: a frame that is mostly ink gives nil", function()
    local g, gw, gh = {}, 20, 30
    for i = 0, gw * gh - 1 do
        if (i % gw) % 4 == 0 then g[i] = 1 end -- a vertical line every 4 columns
    end
    eq(Core.textRect(g, gw, gh, { gap = 1 }), nil)
end)

test("textRect: explicit insets win over detection", function()
    eq(Core.textRect({}, 20, 30, { insets = { 0.1, 0.2, 0.1, 0.25 }, area_w = 1000, area_h = 1500 }),
        { 100, 300, 100, 375 })
end)

test("textRect: right and bottom insets use the real area, not the rounded-up grid", function()
    -- 1072 px is 134 cells exactly; 1450 px needs 182 cells (1456 px).
    eq(Core.textRect({}, 134, 182, { gap = 0, area_w = 1072, area_h = 1450 }), { 0, 0, 0, 0 })
end)

test("textRect: returns the specks it ignored", function()
    local g = ring(20, 30)
    g[15 * 20 + 10] = 1
    local r, specks = Core.textRect(g, 20, 30, { gap = 2 })
    eq(r, { 24, 24, 24, 24 })
    eq(specks, { 15 * 20 + 10 })
end)

test("specksInside: only specks touching the text box are erased", function()
    -- text box x 24..136, y 24..216 in a 160x240 area
    local insets = { 24, 24, 24, 24 }
    local gw = 20
    -- (80,120) inside; (16,16) ends exactly at the box edge, so it doesn't touch; (24,24) does.
    local inside, outside, edge = 15 * gw + 10, 2 * gw + 2, 3 * gw + 3
    eq(Core.specksInside({ inside, outside, edge }, gw, insets, 160, 240, 8),
        { { 80, 120, 8, 8 }, { 24, 24, 8, 8 } })
    eq(Core.specksInside({ inside }, gw, nil, 160, 240, 8), {})
end)

test("specksInside: boxes are clipped to the area", function()
    eq(Core.specksInside({ 19 }, 20, { 0, 0, 0, 0 }, 156, 240, 8), { { 152, 0, 4, 8 } })
end)

-- Margins ----------------------------------------------------------------------

local function scaleBySize(v, ratio) return math.ceil(v * ratio) end

test("unscale: KOReader scales the margin back to at least the wanted pixels", function()
    for _, ratio in ipairs({ 1.0, 1.5, 1.787, 2.06, 2.6 }) do
        for px = 0, 400, 7 do
            local v = Core.unscale(px, ratio)
            local back = scaleBySize(v, ratio)
            assert(back >= px, ("ratio %s px %d -> %d -> %d"):format(ratio, px, v, back))
            assert(back - px <= math.ceil(ratio), ("too far: ratio %s px %d -> %d"):format(ratio, px, back))
        end
    end
end)

test("marginsFor: converts each side", function()
    eq(Core.marginsFor({ 208, 344, 208, 200 }, 2.0), { 104, 172, 104, 100 })
end)

test("marginsEqual", function()
    eq(Core.marginsEqual({ 1, 2, 3, 4 }, { 1, 2, 3, 4 }), true)
    eq(Core.marginsEqual({ 1, 2, 3, 4 }, { 1, 2, 3, 5 }), false)
    eq(Core.marginsEqual({ 1, 2, 3, 4 }, nil), false)
    eq(Core.marginsEqual(nil, nil), true)
end)

-- fontCss ----------------------------------------------------------------------

test("fontCss: nothing without a frame", function()
    eq(Core.fontCss({ font = "Cormorant Garamond", italic = true }, false), "")
end)

test("fontCss: nothing when keeping the book's font, upright", function()
    eq(Core.fontCss({ font = "keep", italic = false }, true), "")
end)

test("fontCss: font only", function()
    local css = Core.fontCss({ font = "Cormorant Garamond", italic = false }, true)
    assert(css:find('body { font-family: "Cormorant Garamond" !important; }', 1, true))
    assert(css:find("code { font-family: monospace !important; }", 1, true))
    assert(not css:find("italic", 1, true))
end)

test("fontCss: italic only keeps the book's font", function()
    local css = Core.fontCss({ font = "keep", italic = true }, true)
    assert(not css:find("font-family", 1, true))
    assert(css:find("body, body * { font-style: italic !important; }", 1, true))
    assert(css:find("em, i, cite", 1, true) and css:find("font-style: normal !important", 1, true))
end)

test("fontCss: italic comes after the font rules, emphasis last", function()
    local css = Core.fontCss({ font = "Cormorant Garamond", italic = true }, true)
    local f, i, n = css:find("font-family", 1, true), css:find("italic", 1, true), css:find("normal", 1, true)
    assert(f < i and i < n)
end)

test("fontCss: quotes in a font name can't break the CSS", function()
    local css = Core.fontCss({ font = 'Evil"; } body { color: red', italic = false }, true)
    assert(css:find('font-family: "Evil; } body { color: red" !important', 1, true))
end)

H.done()
