--[[--
Grayscale-only look for Blossom: soft gray cards, rounded corners and
hearts / flowers from KOReader's fallback fonts (FreeSans / FreeSerif / Noto CJK).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

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
    ribbon = "· ♡ · ❀ · ♡ ·",
}

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

--- "˚ ❀ Blossom ❀ ˚" / title / ribbon, with a ✕ close button on the right.
function Theme.header(title, width, on_close, show_parent)
    local titles = VerticalGroup:new{
        align = "center",
        Theme.vspan(8),
        Theme.text("˚ ❀ Blossom ❀ ˚", Theme.face("ui", 14), { color = Theme.soft_ink }),
        Theme.text(title, Theme.face("script_bold", 28), { max_width = width - Theme.px(120) }),
        Theme.text(Theme.ribbon, Theme.face("ui", 14), { color = Theme.accent }),
        Theme.vspan(4),
    }
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
