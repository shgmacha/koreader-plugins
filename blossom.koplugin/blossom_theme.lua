--[[--
Grayscale-only look for Blossom: soft gray cards, rounded corners and
hearts / flowers from KOReader's fallback fonts (FreeSans / FreeSerif / Noto CJK).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Screen = require("device").screen
local Size = require("ui/size")

local Theme = {
    bg = Blitbuffer.COLOR_WHITE,
    card = Blitbuffer.Color8(0xEE),   -- very soft blush-gray
    petal = Blitbuffer.Color8(0xDD),  -- chart tracks, placeholder tiles
    accent = Blitbuffer.Color8(0x77), -- bars, ribbons, borders
    soft_ink = Blitbuffer.Color8(0x55),
    ink = Blitbuffer.COLOR_BLACK,

    heart = "♥",
    open_heart = "♡",
    flower = "✿",
    blossom = "❀",
    star = "☆",
    ribbon = "· ♡ · ✿ · ♡ ·",
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
        background = opts.background or Theme.card,
        padding = opts.padding or Size.padding.default,
        margin = 0,
        widget,
    }
end

return Theme
