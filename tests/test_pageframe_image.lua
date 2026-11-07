-- Page Frame on a real frame image (the Rose garland by default), with KOReader's own LuaJIT, Blitbuffer and
-- RenderImage. Run from the KOReader app directory:
--   cd ~/Applications/KOReader.app/Contents/koreader && \
--     ./luajit ~/Development/koreader-plugins/tests/test_pageframe_image.lua
local REPO = arg[0]:match("^(.*)/tests/[^/]+$") or "."
package.path = REPO .. "/?.lua;" .. REPO .. "/pageframe.koplugin/?.lua;" .. package.path

require("setupkoenv")
G_reader_settings = require("luasettings"):open(os.getenv("TMPDIR") .. "/pageframe-test-settings.lua")
G_defaults = require("luadefaults"):open()
require("document/canvascontext"):init(require("device")) -- as reader.lua does

local H = require("tests.harness")
local test, eq = H.test, H.eq
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Core = require("pageframe_core")
local PageFrame = dofile(REPO .. "/pageframe.koplugin/main.lua")

-- The rose frame isn't in git (it may be someone else's artwork); a local copy lives in
-- frames-local/, which is gitignored. Override with PAGEFRAME_FRAME=/path/to/image.
local FRAME = os.getenv("PAGEFRAME_FRAME") or (REPO .. "/frames-local/Rose garland.webp")
if not io.open(FRAME, "rb") then
    print("skipped: no frame image at " .. FRAME .. " (set PAGEFRAME_FRAME)")
    os.exit(0)
end
local W, H_ = 1072, 1448 -- Kindle Paperwhite screen
local SOFT = Core.DARKNESS.soft

-- Same buffer, but reported as an unknown type so _buildMask takes its getPixel fallback.
local function slowView(bb)
    return {
        getWidth = function() return bb:getWidth() end,
        getHeight = function() return bb:getHeight() end,
        getType = function() return -1 end,
        getRotation = function() return 0 end,
        getPixel = function(_, x, y) return bb:getPixel(x, y) end,
        data = bb.data, stride = bb.stride,
    }
end

test("the image decodes to RGB32 with real transparency", function()
    local src = RenderImage:renderImageFile(FRAME, false, 268, 362)
    eq(src:getType(), Blitbuffer.TYPE_BBRGB32)
    eq(src:getPixel(134, 181):getColor8A().alpha, 0) -- the empty middle is transparent
    src:free()
end)

test("FFI fast path gives exactly the same mask and grid as the getPixel path", function()
    local src = RenderImage:renderImageFile(FRAME, false, 268, 362)
    local fast, fast_grid = PageFrame._buildMask(src, 1.6, { crisp = true })
    local slow, slow_grid = PageFrame._buildMask(slowView(src), 1.6, { crisp = true })
    local diffs = 0
    for y = 0, 361 do
        for x = 0, 267 do
            if fast:getPixel(x, y):getColor8().a ~= slow:getPixel(x, y):getColor8().a then diffs = diffs + 1 end
        end
    end
    eq(diffs, 0)
    eq(fast_grid, slow_grid)
    fast:free(); slow:free(); src:free()
end)

local full = {}

test("full-size mask builds, and the text box matches the prototype", function()
    local src = RenderImage:renderImageFile(FRAME, false, W, H_)
    local started = os.clock()
    local mask, grid, gw, gh = PageFrame._buildMask(src, SOFT, { crisp = true })
    full.seconds = os.clock() - started
    src:free()
    eq(mask:getType(), Blitbuffer.TYPE_BB8)
    local insets, specks = Core.textRect(grid, gw, gh, { cell = 8, area_w = W, area_h = H_ })
    assert(insets, "expected a text box")
    -- Prototype (spec): L208 T344 R208 B200; allow one cell either way.
    for i, want in ipairs({ 208, 344, 208, 200 }) do
        assert(math.abs(insets[i] - want) <= 8, ("inset %d: got %d, want ~%d"):format(i, insets[i], want))
    end
    full.mask, full.insets, full.specks, full.gw = mask, insets, specks, gw
    print(("     mask built in %.2f s on this Mac; insets L%d T%d R%d B%d"):format(full.seconds, insets[1], insets[2], insets[3], insets[4]))
end)

test("after erasing specks, no drawing at all within 24 px of the text box", function()
    local mask, ins = full.mask, full.insets
    -- What FrameLayer:prepare does: erase the specks textRect ignored that touch the text box.
    local erased = 0
    for _, b in ipairs(Core.specksInside(full.specks, full.gw, ins, W, H_, 8)) do
        mask:paintRect(b[1], b[2], b[3], b[4], Blitbuffer.Color8(0))
        erased = erased + 1
    end
    print(("     erased %d speck cell(s)"):format(erased))
    local x0, y0 = ins[1] - 24, ins[2] - 24
    local x1, y1 = W - ins[3] - 1 + 24, H_ - ins[4] - 1 + 24
    local hits = 0
    for y = y0, y1 do
        for x = x0, x1 do
            if mask:getPixel(x, y):getColor8().a >= Core.INK_SOLID then hits = hits + 1 end
        end
    end
    eq(hits, 0)
end)

test("the mask draws onto a greyscale (BB8) page without touching the text box", function()
    local page = Blitbuffer.new(W, H_, Blitbuffer.TYPE_BB8)
    page:fill(Blitbuffer.COLOR_WHITE)
    page:colorblitFrom(full.mask, 0, 0, 0, 0, W, H_, Blitbuffer.COLOR_BLACK)
    eq(page:getPixel(W / 2, H_ / 2):getColor8().a, 255) -- middle stays white
    local inked = 0
    for x = 0, W - 1, 4 do
        if page:getPixel(x, 120):getColor8().a < 200 then inked = inked + 1 end
    end
    assert(inked > 20, "expected the top garland to be drawn")
    page:free()
    full.mask:free()
end)

H.done()
