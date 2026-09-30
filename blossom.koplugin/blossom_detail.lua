--[[--
Blossom's book detail page: a big cover, progress ribbon and six little
stat cards for one book. Shown on top of the dashboard; covers come from
the dashboard's cache through the `art` callback.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

local Data = require("blossom_data")
local Theme = require("blossom_theme")

local px = Theme.px
local floor = math.floor
local text, vspan, cardInner = Theme.text, Theme.vspan, Theme.cardInner

local BlossomDetail = InputContainer:extend{
    book = nil, -- Data.bookDetail result
    art = nil,  -- function(book, w, h) -> cover widget
    covers_fullscreen = true,
}

function BlossomDetail:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.inner_w = self.width - 2 * px(16)
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

--- The six cards: label glyph, value, caption.
function BlossomDetail:statValues()
    local b = self.book
    local highlights = b.notes > 0
        and string.format(b.notes == 1 and _("%d · %d note") or _("%d · %d notes"), b.highlights, b.notes)
        or tostring(b.highlights)
    return {
        { Theme.open_heart, Data.fmtDuration(b.seconds), _("time together") },
        { Theme.blossom, tostring(b.read_pages), _("pages read") },
        { Theme.flower, tostring(b.days), b.days == 1 and _("reading day") or _("reading days") },
        { Theme.star, b.speed and tostring(b.speed) or "—", _("pages per hour") },
        { Theme.heart, highlights, _("highlights") },
        { "☾", b.finished and Theme.heart or (b.time_left and Data.fmtDuration(b.time_left) or "—"),
          b.finished and _("all read!") or _("left to read") },
    }
end

function BlossomDetail:build()
    local b = self.book
    local gap = px(10)
    local header = Theme.header(_("Book details"), self.width, function() self:onClose() end, self)

    -- Cover beside title, author and progress.
    local cover_w = floor(self.inner_w * 0.36)
    local cover_h = math.min(floor(cover_w * 1.45), floor(self.height * 0.32))
    local info_w = self.inner_w - cover_w - gap
    local pct = floor(b.progress * 100 + 0.5)
    local info = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = b.title,
            face = Theme.face("script_bold", 22),
            width = info_w,
            bgcolor = Theme.bg,
        },
        text(b.authors ~= "" and b.authors or " ", Theme.face("script", 17),
            { color = Theme.soft_ink, max_width = info_w }),
        vspan(10),
        ProgressWidget:new{
            width = info_w,
            height = px(14),
            percentage = b.progress,
            radius = px(7),
            margin_h = 0,
            margin_v = 0,
            bordersize = Size.border.thin,
            bordercolor = Theme.accent,
            bgcolor = Theme.bg,
            fillcolor = Theme.accent,
        },
        vspan(4),
        text(b.finished and string.format(_("finished %s"), Theme.heart) or string.format(_("%d%% read"), pct),
            Theme.face("script", 17), { max_width = info_w }),
        text(b.total_pages > 0 and string.format(_("%d of %d pages"), math.min(b.read_pages, b.total_pages), b.total_pages) or " ",
            Theme.face("ui", 14), { color = Theme.soft_ink, max_width = info_w }),
    }
    local polaroid = FrameContainer:new{
        bordersize = Size.border.thin,
        color = Theme.accent,
        radius = px(8),
        background = Theme.bg,
        padding = px(4),
        margin = 0,
        self.art(b, cover_w - 2 * (px(4) + Size.border.thin), cover_h),
    }
    local top = HorizontalGroup:new{
        align = "top",
        polaroid,
        HorizontalSpan:new{ width = gap },
        info,
    }

    -- 3 rows × 2 cards.
    local card_w = floor((self.inner_w - gap) / 2)
    local inner = cardInner(card_w)
    local dates = string.format(_("first read %s · last read %s"), b.first or "—", b.last or "—")
    local footer = text(dates, Theme.face("script", 15), { color = Theme.soft_ink, max_width = self.inner_w })
    local used = header:getSize().h + top:getSize().h + footer:getSize().h + gap * 6
    local card_h = math.min(px(70), floor((self.height - used) / 3) - 2 * (Size.padding.default + Size.border.thin))
    local grid = VerticalGroup:new{ align = "center" }
    local values = self:statValues()
    for r = 0, 2 do
        local row = HorizontalGroup:new{}
        for c = 1, 2 do
            local v = values[r * 2 + c]
            if c == 2 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, Theme.card(CenterContainer:new{
                dimen = Geom:new{ w = inner, h = card_h },
                VerticalGroup:new{
                    align = "center",
                    text(v[1] .. " " .. v[2], Theme.face("bold", 20), { max_width = inner }),
                    text(v[3], Theme.face("script", 15), { color = Theme.soft_ink, max_width = inner }),
                },
            }))
        end
        if r > 0 then table.insert(grid, VerticalSpan:new{ width = gap }) end
        table.insert(grid, row)
    end

    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Theme.bg,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            header,
            VerticalSpan:new{ width = gap },
            top,
            VerticalSpan:new{ width = gap * 2 },
            grid,
            VerticalSpan:new{ width = gap },
            footer,
            vspan(4),
            text(_("happy reading ♡"), Theme.face("script", 15), { color = Theme.accent }),
        },
    }
end

function BlossomDetail:onSwipe(_, ges)
    if ges.direction == "south" or ges.direction == "east" then return self:onClose() end
    return true
end

function BlossomDetail:onClose()
    UIManager:close(self)
    return true
end

function BlossomDetail:onCloseWidget()
    -- Cover blitbuffers belong to the dashboard; this only frees scaled copies.
    if self[1] then self[1]:free() end
    UIManager:setDirty(nil, "full")
end

return BlossomDetail
