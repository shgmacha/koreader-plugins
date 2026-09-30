--[[--
Grayscale-only look for Blossom: soft gray cards, rounded corners and
hearts / flowers from KOReader's fallback fonts (FreeSans / FreeSerif / Noto CJK).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
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

--- "· ♡ ·  bow  · ♡ ·" decoration line.
function Theme.ribbon(size)
    local function side() return Theme.text("· ♡ ·", Theme.face("ui", 14), { color = Theme.accent }) end
    return HorizontalGroup:new{
        align = "center",
        side(), HorizontalSpan:new{ width = Theme.px(8) }, Theme.bow(size or 26),
        HorizontalSpan:new{ width = Theme.px(8) }, side(),
    }
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

--- "˚ ❀ Blossom ❀ ˚" / title / bow ribbon, with a ✕ close button on the right.
--- opts.title_size and opts.subtitle make a bigger journal-style title.
function Theme.header(title, width, on_close, show_parent, opts)
    opts = opts or {}
    local titles = VerticalGroup:new{
        align = "center",
        Theme.vspan(8),
        Theme.text("˚ ❀ Blossom ❀ ˚", Theme.face("ui", 14), { color = Theme.soft_ink }),
        Theme.text(title, Theme.face("script_bold", opts.title_size or 28), { max_width = width - Theme.px(120) }),
    }
    if opts.subtitle then
        table.insert(titles, Theme.text(opts.subtitle, Theme.face("script", 17), { color = Theme.soft_ink }))
    end
    table.insert(titles, Theme.vspan(2))
    table.insert(titles, Theme.ribbon())
    table.insert(titles, Theme.vspan(4))
    local close = Button:new{
        text = "✕",
        bordersize = 0,
        text_font_size = 22,
        callback = on_close,
        show_parent = show_parent,
    }
    close.overlap_align = "right"
    titles.overlap_align = "center"
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = titles:getSize().h },
        titles,
        close,
    }
end

return Theme
