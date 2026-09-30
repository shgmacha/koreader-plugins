--[[--
Grayscale-only look for Blossom: soft gray cards, rounded corners and
hearts / flowers from KOReader's fallback fonts (FreeSans / FreeSerif / Noto CJK).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Theme = {
    bg = Blitbuffer.COLOR_WHITE,
    card_bg = Blitbuffer.Color8(0xEE), -- very soft blush-gray
    petal = Blitbuffer.Color8(0xDD),  -- chart tracks, placeholder tiles
    accent = Blitbuffer.Color8(0x77), -- ribbons, borders, best bar
    bar = Blitbuffer.Color8(0x99),    -- chart bars
    soft_ink = Blitbuffer.Color8(0x55),
    ink = Blitbuffer.COLOR_BLACK,

    heart = "♥",
    open_heart = "♡",
    flower = "❀",
    blossom = "❀",
    star = "☆",
}

-- This plugin's folder, for the bow icon.
Theme.dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

-- Calendar shades by reading level (none, <15m, <45m, 45m+).
Theme.shades = {
    Blitbuffer.COLOR_WHITE,
    Blitbuffer.Color8(0xE6),
    Blitbuffer.Color8(0xBB),
    Blitbuffer.Color8(0x88),
}

-- Page margins shared by every page: sides, and the space under the header.
Theme.MARGIN = 34
Theme.TOP_GAP = 36

function Theme.px(n)
    return Screen:scaleBySize(n)
end

local faces = {}
--- Serif italic for the "handwritten diary" feel; falls back to the UI font.
function Theme.face(kind, size)
    local key = kind .. size
    if not faces[key] then
        local name = ({ script = "NotoSerif-Italic.ttf", script_bold = "NotoSerif-BoldItalic.ttf",
                        bold = "NotoSans-Bold.ttf" })[kind] or "cfont"
        faces[key] = Font:getFace(name, size) or Font:getFace("cfont", size)
    end
    return faces[key]
end

--- Rounded soft card.
function Theme.card(widget, opts)
    opts = opts or {}
    return FrameContainer:new{
        radius = opts.radius or Size.radius.window,
        bordersize = opts.bordersize or Size.border.thin,
        color = opts.border_color or Theme.accent,
        background = opts.background or Theme.card_bg,
        padding = opts.padding or Size.padding.default,
        margin = 0,
        widget,
    }
end

--- A rounded frame whose content may touch its edges (like a cover flush at the top):
--- content is painted first, the corners are trimmed to the curve, then the border.
Theme.RoundedFrame = WidgetContainer:extend{
    radius = 10,
    bordersize = 1,
    color = nil,      -- border color
    background = nil, -- inside the frame
    outside = nil,    -- page color used to trim the corners
}

function Theme.RoundedFrame:getSize()
    local size = self[1]:getSize()
    return Geom:new{ w = size.w + 2 * self.bordersize, h = size.h + 2 * self.bordersize }
end

function Theme.RoundedFrame:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h, r, b = size.w, size.h, self.radius, self.bordersize
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    bb:paintRoundedRect(x, y, w, h, self.background, r)
    self[1]:paintTo(bb, x + b, y + b)
    -- Trim whatever the content painted outside the rounded corners.
    for dy = 0, r - 1 do
        local yy = r - dy - 0.5
        local cut = math.ceil(r - math.sqrt(math.max(0, r * r - yy * yy)) - 0.5)
        if cut > 0 then
            bb:paintRect(x, y + dy, cut, 1, self.outside)
            bb:paintRect(x + w - cut, y + dy, cut, 1, self.outside)
            bb:paintRect(x, y + h - 1 - dy, cut, 1, self.outside)
            bb:paintRect(x + w - cut, y + h - 1 - dy, cut, 1, self.outside)
        end
    end
    bb:paintBorder(x, y, w, h, b, self.color, r)
end

--- The yearly goal as a wavy line: bold and solid up to where you are, soft and dotted after.
Theme.GoalWave = Widget:extend{
    width = 0,
    height = 0,
    ratio = 0,
    mid = 0,        -- y of the wave's centre line
    amplitude = 6,
    period = 48,
}

--- Wave height at x (relative to the widget's top).
function Theme.GoalWave:waveY(x)
    return self.mid + self.amplitude * math.sin(2 * math.pi * x / self.period)
end

function Theme.GoalWave:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Theme.GoalWave:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local done_w = math.floor(self.width * self.ratio + 0.5)
    local thick, thin = Theme.px(4), Theme.px(2)
    local dot = Theme.px(5)
    for dx = 0, self.width - 1 do
        local wy = math.floor(self:waveY(dx) + 0.5)
        if dx <= done_w and self.ratio > 0 then
            bb:paintRect(x + dx, y + wy - math.floor(thick / 2), 1, thick, Theme.accent)
        elseif math.floor(dx / dot) % 2 == 0 then
            bb:paintRect(x + dx, y + wy - math.floor(thin / 2), 1, thin, Theme.shades[3])
        end
    end
end

--- The wavy goal line with a heart riding it where you are.
function Theme.wave(ratio, width)
    ratio = math.max(0, math.min(1, ratio))
    local heart_w = Theme.px(16)
    local heart = Theme.heartIcon(16)
    local heart_h = math.floor(heart_w * 44 / 48)
    local amplitude = Theme.px(6)
    local mid = Theme.px(2) + amplitude + math.floor(heart_h / 2)
    local height = mid + amplitude + math.floor(heart_h / 2) + Theme.px(2)
    local wave = Theme.GoalWave:new{ width = width, height = height, ratio = ratio, mid = mid,
                               amplitude = amplitude, period = Theme.px(48) }
    local fill_x = math.floor(width * ratio)
    local heart_x = math.max(0, math.min(width - heart_w, fill_x - math.floor(heart_w / 2)))
    local heart_y = math.floor(wave:waveY(heart_x + math.floor(heart_w / 2)) - heart_h / 2)
    heart.overlap_offset = { heart_x, heart_y }
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height },
        wave,
        heart,
    }
end

--- A highlight with a soft bar on its left: the text as in the book, a small gray `meta` line, then the note.
--- Short quotes take their natural height; long ones stop at `max_lines` with an ellipsis.
function Theme.quote(quote_text, meta, note, width, max_lines, size)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    size = size or 17
    local bar_w, pad = Theme.px(3), Theme.px(12)
    local inner = width - bar_w - pad
    local face = Theme.face("script", size)
    local function box(height)
        return TextBoxWidget:new{
            -- exactly as in the book: no added quote marks, so the book's own are unmistakable
            text = ((quote_text or ""):gsub("^%s+", ""):gsub("%s+$", "")),
            face = face,
            width = inner,
            height = height,
            height_overflow_show_ellipsis = true,
            bgcolor = Theme.bg,
        }
    end
    local quote = box()
    local max_h = math.floor((max_lines or 4) * face.size * 1.45)
    if quote:getSize().h > max_h then
        quote:free()
        quote = box(max_h)
    end
    local body = VerticalGroup:new{
        align = "left",
        quote,
        Theme.vspan(2),
        Theme.text(meta, Theme.face("script", size - 4), { color = Theme.soft_ink, max_width = inner }),
    }
    if note then
        table.insert(body, Theme.vspan(2))
        table.insert(body, Theme.text("✎ " .. note, Theme.face("script", size - 2), { max_width = inner }))
    end
    local bar = LineWidget:new{
        background = Theme.shades[3],
        dimen = Geom:new{ w = bar_w, h = body:getSize().h },
    }
    body:resetLayout()
    return HorizontalGroup:new{ align = "top", bar, HorizontalSpan:new{ width = pad }, body }
end

--- Frameless little stats: glyph + value over a soft label, in `cols` columns.
function Theme.statGrid(items, width, cols, opts)
    local CenterContainer = require("ui/widget/container/centercontainer")
    opts = opts or {}
    local col_w = math.floor(width / cols)
    local grid = VerticalGroup:new{ align = "center" }
    local row
    for i, item in ipairs(items) do
        if (i - 1) % cols == 0 then
            if row then table.insert(grid, Theme.vspan(opts.row_gap or 12)) end
            row = HorizontalGroup:new{ align = "top" }
            table.insert(grid, row)
        end
        -- item = { glyph, value, label[, icon widget] }: a drawn icon sits above the value instead of the glyph.
        local body = VerticalGroup:new{ align = "center" }
        if item[4] then
            table.insert(body, item[4])
            table.insert(body, Theme.vspan(4))
        end
        local value_face = Theme.face("bold", opts.value_size or 16)
        if type(item[1]) == "table" and not item[4] then
            -- a drawn icon (widget) beside the value
            table.insert(body, HorizontalGroup:new{
                align = "center",
                item[1],
                HorizontalSpan:new{ width = Theme.px(5) },
                Theme.text(item[2], value_face, { max_width = col_w }),
            })
        else
            table.insert(body, Theme.text(item[4] and item[2] or (item[1] .. " " .. item[2]), value_face, { max_width = col_w }))
        end
        table.insert(body, Theme.text(item[3], Theme.face("script", opts.label_size or 13), { color = Theme.soft_ink, max_width = col_w }))
        local cell = CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = Theme.px(opts.cell_h or 46) },
            body,
        }
        table.insert(row, opts.wrap and opts.wrap(cell, i) or cell)
    end
    return grid
end

--- Makes any widget tappable.
Theme.Tappable = InputContainer:extend{
    callback = nil,
}

function Theme.Tappable:init()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function Theme.Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

--- Fills one page of a list: rows from items[start] while they fit in avail_h (always at least one).
--- make_row(item, index, previous_item_on_page) -> widget. Returns the group and the next start index.
function Theme.fillPage(items, start, avail_h, make_row, gap)
    local group = VerticalGroup:new{ align = "left" }
    local i, prev = start, nil
    gap = gap or Theme.px(14)
    while i <= #items do
        local row = make_row(items[i], i, prev)
        local h = group:getSize().h
        group:resetLayout()
        if #group > 0 and h + gap + row:getSize().h > avail_h then
            row:free()
            break
        end
        if #group > 0 then table.insert(group, VerticalSpan:new{ width = gap }) end
        table.insert(group, row)
        prev = items[i]
        i = i + 1
    end
    return group, i
end

--- Where each page of a list starts, found by filling pages one after another.
function Theme.pageStarts(items, avail_h, make_row, gap)
    local starts, i = { 1 }, 1
    while i <= #items do
        local group, next_i = Theme.fillPage(items, i, avail_h, make_row, gap)
        group:free()
        i = next_i
        if i <= #items then starts[#starts + 1] = i end
    end
    return starts
end

--- The pager used everywhere: ‹  • • 🌱 • •  › — soft dots, a sprout for the current page.
--- Long runs show a window of dots around the current page plus a small "12 / 40".
Theme.PAGER_DOTS = 9
function Theme.pager(page, total, on_prev, on_next)
    local Button = require("ui/widget/button")
    local function arrow(glyph, enabled, fn)
        return Button:new{ text = glyph, bordersize = 0, width = Theme.px(44), text_font_size = 22,
                           enabled = enabled, callback = fn }
    end
    local first, last = 1, total
    if total > Theme.PAGER_DOTS then
        first = math.max(1, math.min(page - 3, total - 6))
        last = first + 6
    end
    local dots = HorizontalGroup:new{ align = "center" }
    for i = first, last do
        if i > first then table.insert(dots, HorizontalSpan:new{ width = Theme.px(10) }) end
        if i == page then
            table.insert(dots, Theme.icon("sprout", 20))
        else
            table.insert(dots, Theme.text("●", Theme.face("ui", 9), { color = Theme.shades[3] }))
        end
    end
    local row = HorizontalGroup:new{
        align = "center",
        arrow("‹", page > 1, on_prev),
        HorizontalSpan:new{ width = Theme.px(12) },
        dots,
        HorizontalSpan:new{ width = Theme.px(12) },
        arrow("›", page < total, on_next),
    }
    if total > Theme.PAGER_DOTS then
        table.insert(row, HorizontalSpan:new{ width = Theme.px(4) })
        table.insert(row, Theme.text(string.format("%d / %d", page, total), Theme.face("script", 12), { color = Theme.soft_ink }))
    end
    return row
end

-- Where Blossom's pages sit: full screen, or a floating window over the bookshelf or book.
Theme.layout = { window = false }
Theme.WINDOW_W, Theme.WINDOW_H = 0.9, 0.88

--- Page geometry: content size (w, h), outer size and position.
function Theme.pageGeometry()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not Theme.layout.window then
        return { x = 0, y = 0, w = sw, h = sh, outer_w = sw, outer_h = sh, window = false, border = 0 }
    end
    local ow, oh = math.floor(sw * Theme.WINDOW_W), math.floor(sh * Theme.WINDOW_H)
    local b = Size.border.thick
    return { x = math.floor((sw - ow) / 2), y = math.floor((sh - oh) / 2), w = ow - 2 * b, h = oh - 2 * b,
             outer_w = ow, outer_h = oh, window = true, border = b }
end

--- Sets a page widget's size and area; a window doesn't cover what's underneath.
function Theme.initPage(page)
    local g = Theme.pageGeometry()
    page.geom = g
    page.width, page.height = g.w, g.h
    page.dimen = Geom:new{ x = g.x, y = g.y, w = g.outer_w, h = g.outer_h }
    page.covers_fullscreen = not g.window
end

--- In a window, tapping outside it closes it (call after setting ges_events).
function Theme.addWindowGestures(page)
    if not page.geom.window or not require("device"):isTouchDevice() then return end
    page.ges_events = page.ges_events or {}
    page.ges_events.TapOutside = {
        GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    page.onTapOutside = function(self, _, ges)
        local g, p = self.geom, ges and ges.pos
        if p and (p.x < g.x or p.x > g.x + g.outer_w or p.y < g.y or p.y > g.y + g.outer_h) then
            return self:onClose()
        end
        return true
    end
end

--- A page's outer frame: plain for full screen, a rounded bordered window otherwise.
function Theme.pageFrame(page, content)
    local g = page.geom
    return FrameContainer:new{
        width = g.outer_w,
        height = g.outer_h,
        background = Theme.bg,
        bordersize = g.border,
        radius = g.window and Theme.px(18) or nil,
        color = Theme.ink,
        padding = 0,
        margin = 0,
        content,
    }
end

--- Shows a page in its place (full screen, or centred as a window).
function Theme.showPage(page)
    require("ui/uimanager"):show(page, "flashui", nil, page.geom.x, page.geom.y)
end

--- Width left for content inside a default Theme.card.
function Theme.cardInner(w)
    return w - 2 * (Size.padding.default + Size.border.thin)
end

function Theme.text(str, face, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = face,
        fgcolor = opts.color or Theme.ink,
        max_width = opts.max_width,
    }
end

function Theme.vspan(n)
    return VerticalSpan:new{ width = Theme.px(n) }
end

--- A little drawn bow (e-reader fonts don't have one). `size` is its width.
function Theme.bow(size)
    size = Theme.px(size or 20)
    return ImageWidget:new{
        file = Theme.dir .. "/icons/bow.svg",
        width = size,
        height = math.floor(size * 0.75),
        alpha = true,
    }
end

--- One of the drawn garden icons in icons/ (tulip, daisy, rose, sprout, ...). `w`, `h` unscaled;
--- pass `exact` when they are already in screen pixels.
function Theme.icon(name, w, h, exact)
    local scale = exact and function(n) return n end or Theme.px
    return ImageWidget:new{
        file = Theme.dir .. "/icons/" .. name .. ".svg",
        width = scale(w),
        height = scale(h or w),
        alpha = true,
    }
end

--- A little drawn heart (filled soft gray, dark outline). `size` is its width.
function Theme.heartIcon(size)
    size = Theme.px(size or 24)
    return ImageWidget:new{
        file = Theme.dir .. "/icons/heart.svg",
        width = size,
        height = math.floor(size * 44 / 48),
        alpha = true,
    }
end

--- The little pencil (tip pointing down-left). `size` is its width.
function Theme.pencilIcon(size)
    size = Theme.px(size or 20)
    return ImageWidget:new{
        file = Theme.dir .. "/icons/pencil.svg",
        width = size,
        height = size,
        alpha = true,
    }
end

--- A widget with a bow beside it ("left" or "right", default right).
function Theme.withBow(widget, size, side)
    local bow, gap = Theme.bow(size), HorizontalSpan:new{ width = Theme.px(6) }
    if side == "left" then
        return HorizontalGroup:new{ align = "center", bow, gap, widget }
    end
    return HorizontalGroup:new{ align = "center", widget, gap, bow }
end

--- A little row of flowers of different heights, standing on the same ground.
function Theme.ribbon()
    local row = HorizontalGroup:new{ align = "bottom" }
    for i, f in ipairs({ { "sprout", 16 }, { "bud", 19 }, { "daisy", 23 }, { "tulip", 26 }, { "daisy", 23 }, { "bud", 19 }, { "sprout", 16 } }) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = Theme.px(2) }) end
        table.insert(row, Theme.icon(f[1], f[2]))
    end
    return row
end

--- Borderless soft strip of little stats: value over label, evenly spaced.
function Theme.statStrip(items, width, radius)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local inner = Theme.cardInner(width)
    local col_w = math.floor(inner / #items)
    local row = HorizontalGroup:new{ align = "center" }
    for _, item in ipairs(items) do
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = Theme.px(52) },
            VerticalGroup:new{
                align = "center",
                Theme.text(item[1], Theme.face("bold", 18), { max_width = col_w }),
                Theme.text(item[2], Theme.face("script", 14), { color = Theme.soft_ink, max_width = col_w }),
            },
        })
    end
    return Theme.card(row, { bordersize = 0, radius = radius or Theme.px(18) })
end

--- A quiet section label: ─── label ───
function Theme.rule(label, width)
    local t = Theme.text(label, Theme.face("script", 16), { color = Theme.soft_ink })
    local line_w = math.max(Theme.px(10), math.floor((width - t:getSize().w) / 2) - Theme.px(12))
    local function line()
        return LineWidget:new{ background = Theme.petal, dimen = Geom:new{ w = line_w, h = Size.line.medium } }
    end
    return HorizontalGroup:new{
        align = "center",
        line(), HorizontalSpan:new{ width = Theme.px(12) }, t, HorizontalSpan:new{ width = Theme.px(12) }, line(),
    }
end

--- "Blossom" between flowers / title / a row of flowers, with a flower close button on the left.
--- opts.title_size and opts.subtitle make a bigger journal-style title.
function Theme.header(title, width, on_close, show_parent, opts)
    -- opts.back: a page opened from the dashboard gets a back flower (‹) instead of close (×).
    opts = opts or {}
    local titles = VerticalGroup:new{
        align = "center",
        Theme.vspan(8),
        -- "Blossom" between two little lilies
        HorizontalGroup:new{
            align = "center",
            Theme.icon("lily", 18),
            HorizontalSpan:new{ width = Theme.px(5) },
            Theme.text("Blossom", Theme.face("ui", 12), { color = Theme.soft_ink }),
            HorizontalSpan:new{ width = Theme.px(5) },
            Theme.icon("lily", 18),
        },
        Theme.text(title, Theme.face("script_bold", opts.title_size or 23), { max_width = width - Theme.px(120) }),
    }
    if opts.subtitle then
        table.insert(titles, Theme.text(opts.subtitle, Theme.face("script", 15), { color = Theme.soft_ink }))
    end
    table.insert(titles, Theme.vspan(2))
    table.insert(titles, Theme.ribbon())
    table.insert(titles, Theme.vspan(4))
    -- A cute flower close button, top-left on the page margin.
    local close = Theme.Tappable:new{
        callback = on_close,
        Theme.icon((opts and opts.back) and "back_flower" or "close_flower", 34),
    }
    -- level with the page title rather than the very top edge
    close.overlap_offset = { Theme.px(Theme.MARGIN) - Theme.px(4), Theme.px(36) }

    titles.overlap_align = "center"
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = titles:getSize().h },
        titles,
        close,
    }
end

return Theme
