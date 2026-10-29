--[[--
Goodreads Sync's look, after the "brew" app's design: warm paper surfaces, an
espresso title bar and espresso section headers with light type, softly rounded
cards with a quiet border, a serif for titles and a sans for everything else.
On e-ink the palette becomes grayscale: cream -> light paper, espresso -> near
black, blush -> light gray. Every page floats over the book as a window.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")

local Theme = {
    bg = Blitbuffer.Color8(0xF7),      -- paper (brew's cream)
    card_bg = Blitbuffer.Color8(0xF7), -- cards sit on the same paper, set apart by their border
    tile_bg = Blitbuffer.Color8(0xE6), -- recessed: cover placeholders, empty bar (brew's muted bg)
    line = Blitbuffer.Color8(0x9A),    -- quiet borders (espresso at ~40%)
    muted = Blitbuffer.Color8(0x5C),   -- secondary text
    ink = Blitbuffer.Color8(0x1E),     -- text and primary buttons (espresso)
    bar = Blitbuffer.Color8(0x2E),     -- title bar and section headers (espresso)
    on_bar = Blitbuffer.Color8(0xF0),  -- type on the bars (blush)

    star = "★",
    empty_star = "☆",
}
Theme.soft_ink = Theme.muted

-- Page margins: sides, and the space under the header.
Theme.MARGIN = 28
Theme.TOP_GAP = 18

function Theme.px(n)
    return Screen:scaleBySize(n)
end

local faces = {}
local FACE_FILES = {
    bold = "NotoSans-Bold.ttf",          -- numbers, emphasis
    serif = "NotoSerif-Regular.ttf",     -- (brew: Fraunces for headings)
    serif_bold = "NotoSerif-Bold.ttf",   -- page and section titles
}
--- "serif_bold" for titles, "bold" for numbers, anything else for regular sans text.
function Theme.face(kind, size)
    local key = tostring(kind) .. size
    if not faces[key] then
        local file = FACE_FILES[kind]
        faces[key] = (file and Font:getFace(file, size)) or Font:getFace("cfont", size)
    end
    return faces[key]
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

--- Brew's card: rounded, quiet border, and a solid espresso header with light serif type.
Theme.Section = Widget:extend{
    title = "",
    width = 0,
    pad = 10,
}

function Theme.Section:init()
    local pad = Theme.px(self.pad)
    self[1] = Theme.text(self.title, Theme.face("serif_bold", self.header_size or 15),
        { color = Theme.on_bar, max_width = self.width - 2 * pad })
    self[2] = self.body
    self.header_h = self[1]:getSize().h + 2 * Theme.px(7)
end

function Theme.Section:getSize()
    local pad = Theme.px(self.pad)
    return Geom:new{ w = self.width, h = self.header_h + self[2]:getSize().h + 2 * pad }
end

function Theme.Section:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h, r, pad = size.w, size.h, Theme.px(10), Theme.px(self.pad)
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    bb:paintRoundedRect(x, y, w, h, Theme.card_bg, r)
    bb:paintRoundedRect(x, y, w, self.header_h, Theme.bar, r)
    bb:paintRect(x, y + self.header_h - r, w, r, Theme.bar) -- square under the header
    local title_h = self[1]:getSize().h
    self[1]:paintTo(bb, x + pad, y + math.floor((self.header_h - title_h) / 2))
    self[2]:paintTo(bb, x + pad, y + self.header_h + pad)
    bb:paintBorder(x, y, w, h, Size.border.thin, Theme.line, r)
end

function Theme.Section:free()
    for _, c in ipairs(self) do if c.free then c:free() end end
end

--- title: header text; body: the card's content (at most sectionInner(width) wide).
function Theme.section(title, body, width, opts)
    opts = opts or {}
    return Theme.Section:new{ title = title, body = body, width = width, pad = opts.pad, header_size = opts.header_size }
end

--- Width left for content inside a Theme.section.
function Theme.sectionInner(w, pad)
    return w - 2 * Theme.px(pad or 10)
end

--- A light card with a thin border (opts.bordersize = 0 for a borderless one).
--- opts.width: the card's full width (its content is left-aligned inside).
function Theme.card(widget, opts)
    opts = opts or {}
    if opts.width then
        -- KOReader sizes a frame by its content, so widen the content itself.
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local inner = opts.width - 2 * ((opts.padding or Size.padding.default) + (opts.bordersize or Size.border.thin))
        widget = LeftContainer:new{ dimen = Geom:new{ w = inner, h = widget:getSize().h }, widget }
    end
    return FrameContainer:new{
        radius = opts.radius or Theme.px(10),
        bordersize = opts.bordersize or Size.border.thin,
        color = opts.border_color or Theme.line,
        background = opts.background or Theme.card_bg,
        padding = opts.padding or Size.padding.default,
        margin = 0,
        widget,
    }
end

--- Width left for content inside a default Theme.card.
function Theme.cardInner(w)
    return w - 2 * (Size.padding.default + Size.border.thin)
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

--- A plain progress bar (goal, reading progress).
Theme.ProgressBar = Widget:extend{
    width = 0,
    height = 0,
    ratio = 0,
}

function Theme.ProgressBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Theme.ProgressBar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Theme.tile_bg)
    local done = math.floor(self.width * math.max(0, math.min(1, self.ratio)) + 0.5)
    if done > 0 then bb:paintRect(x, y, done, self.height, Theme.bar) end
end

function Theme.progressBar(ratio, width)
    return Theme.ProgressBar:new{ width = width, height = Theme.px(8), ratio = ratio }
end

--- Fills one page of a list: rows from items[start] while they fit in avail_h (always at least one).
function Theme.fillPage(items, start, avail_h, make_row, gap)
    local group = VerticalGroup:new{ align = "left" }
    local i = start
    gap = gap or Theme.px(12)
    while i <= #items do
        local row = make_row(items[i], i)
        local h = group:getSize().h
        group:resetLayout()
        if #group > 0 and h + gap + row:getSize().h > avail_h then
            row:free()
            break
        end
        if #group > 0 then table.insert(group, VerticalSpan:new{ width = gap }) end
        table.insert(group, row)
        i = i + 1
    end
    return group, i
end

--- Page dots with arrows: ‹  ○ ● ○  ›  (a window of dots plus "12 / 40" on long lists).
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
        if i > first then table.insert(dots, HorizontalSpan:new{ width = Theme.px(8) }) end
        table.insert(dots, Theme.text(i == page and "●" or "○", Theme.face("regular", 11),
            { color = i == page and Theme.ink or Theme.line }))
    end
    local row = HorizontalGroup:new{
        align = "center",
        arrow("‹", page > 1, on_prev),
        HorizontalSpan:new{ width = Theme.px(10) },
        dots,
        HorizontalSpan:new{ width = Theme.px(10) },
        arrow("›", page < total, on_next),
    }
    if total > Theme.PAGER_DOTS then
        table.insert(row, HorizontalSpan:new{ width = Theme.px(4) })
        table.insert(row, Theme.text(string.format("%d / %d", page, total), Theme.face("regular", 12), { color = Theme.muted }))
    end
    return row
end

-- Pages always float over the book or bookshelf.
Theme.layout = { window = true }
Theme.WINDOW_W, Theme.WINDOW_H = 0.9, 0.88

--- Page geometry: content size (w, h), outer size and position.
function Theme.pageGeometry()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
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
    page.covers_fullscreen = false
end

--- Tapping outside the window closes it (call after setting ges_events).
function Theme.addWindowGestures(page)
    if not require("device"):isTouchDevice() then return end
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

--- A page's window frame.
function Theme.pageFrame(page, content)
    local g = page.geom
    return FrameContainer:new{
        width = g.outer_w,
        height = g.outer_h,
        background = Theme.bg,
        bordersize = g.border,
        radius = Theme.px(10),
        color = Theme.ink,
        padding = 0,
        margin = 0,
        content,
    }
end

--- Shows a page in its place (centred as a window).
function Theme.showPage(page)
    require("ui/uimanager"):show(page, "flashui", nil, page.geom.x, page.geom.y)
end

--- A small section label over a thin line: "SHELVES ────────".
function Theme.rule(label, width)
    local t = Theme.text(label:upper(), Theme.face("bold", 12), { color = Theme.muted })
    local line_w = math.max(Theme.px(10), width - t:getSize().w - Theme.px(10))
    return HorizontalGroup:new{
        align = "center",
        t,
        HorizontalSpan:new{ width = Theme.px(10) },
        LineWidget:new{ background = Theme.line, dimen = Geom:new{ w = line_w, h = Size.line.thin } },
    }
end

-- The window's espresso title bar (top corners follow the window's rounding).
Theme.TitleBar = Widget:extend{ width = 0, height = 0 }

function Theme.TitleBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Theme.TitleBar:paintTo(bb, x, y)
    local r = Theme.px(8)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRoundedRect(x, y, self.width, self.height, Theme.bar, r)
    bb:paintRect(x, y + self.height - r, self.width, r, Theme.bar)
end

--- Page header: an espresso title bar with a serif title (and subtitle) in light type,
--- and a × (or ‹ back) button on the left.
function Theme.header(title, width, on_close, _show_parent, opts)
    opts = opts or {}
    local title_w = Theme.text(title, Theme.face("serif_bold", 21), { color = Theme.on_bar, max_width = width - Theme.px(120) })
    local h = title_w:getSize().h + 2 * Theme.px(12)
    local sub
    if opts.subtitle then
        sub = Theme.text(opts.subtitle, Theme.face("regular", 14), { color = Theme.on_bar, max_width = width - Theme.px(120) })
        h = h + sub:getSize().h + Theme.px(1)
    end
    local titles = VerticalGroup:new{ align = "center", Theme.vspan(12), title_w }
    if sub then
        table.insert(titles, Theme.vspan(1))
        table.insert(titles, sub)
    end
    titles.overlap_align = "center"
    local close = Theme.Tappable:new{
        callback = on_close,
        Theme.text(opts.back and "‹" or "×", Theme.face("regular", 30), { color = Theme.on_bar }),
    }
    close.overlap_offset = { Theme.px(Theme.MARGIN) - Theme.px(8), math.max(0, math.floor((h - Theme.px(40)) / 2)) }
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        Theme.TitleBar:new{ width = width, height = h },
        titles,
        close,
    }
end

return Theme
