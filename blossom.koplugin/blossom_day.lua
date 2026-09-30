--[[--
Blossom's day page: the books read on one day, and the highlights and
bookmarks made that day. Opened by tapping a day in the month calendar.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
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

local MAX_BOOKS = 3

local BlossomDay = InputContainer:extend{
    day = nil,       -- loadDay result: period summary + date + notes
    art = nil,       -- function(book, w, h) -> cover widget
    tappable = nil,  -- function(widget, book) -> tappable widget opening the book
    covers_fullscreen = true,
}

function BlossomDay:init()
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

local function section(title)
    return text(title, Theme.face("script_bold", 19))
end

local function muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
end

function BlossomDay:bookRow(b, row_h)
    local inner = cardInner(self.inner_w)
    local thumb_w = floor(row_h / 1.45)
    local body_w = inner - thumb_w - px(12)
    local body = VerticalGroup:new{
        align = "left",
        text(b.title, Theme.face("bold", 16), { max_width = body_w }),
        muted(b.authors ~= "" and b.authors or " ", 14, body_w),
        text(string.format(_("%s · %d pages %s"), Data.fmtDuration(b.seconds), b.pages,
            b.finished and Theme.heart or ""), Theme.face("script", 15), { max_width = body_w }),
    }
    return self.tappable(Theme.card(HorizontalGroup:new{
        align = "center",
        self.art(b, thumb_w, row_h),
        HorizontalSpan:new{ width = px(12) },
        LeftContainer:new{ dimen = Geom:new{ w = body_w, h = row_h }, body },
    }), b)
end

--- A soft quote card: “text” — Book · p. 12, plus the reader's note.
function BlossomDay:highlightCard(h, max_lines)
    local inner = cardInner(self.inner_w)
    local function quoteBox(height)
        return TextBoxWidget:new{
            text = "“" .. (h.text or "") .. "”",
            face = Theme.face("script", 16),
            width = inner,
            height = height,
            height_overflow_show_ellipsis = true,
            bgcolor = Theme.card_bg,
        }
    end
    -- Natural height for short quotes; long ones are cut at max_lines with an ellipsis.
    local quote = quoteBox()
    local max_h = floor(max_lines * Theme.face("script", 16).size * 1.45)
    if quote:getSize().h > max_h then
        quote:free()
        quote = quoteBox(max_h)
    end
    local where = { h.title }
    if h.page then where[#where + 1] = string.format(_("p. %d"), h.page) end
    where[#where + 1] = h.time
    local group = VerticalGroup:new{
        align = "left",
        quote,
        vspan(2),
        muted("— " .. table.concat(where, " · "), 13, inner),
    }
    if h.note then
        table.insert(group, text("✎ " .. h.note, Theme.face("script", 14), { max_width = inner }))
    end
    return Theme.card(group)
end

function BlossomDay:build()
    local day = self.day
    local gap = px(10)
    local header = Theme.header(Data.dayTitle(day.date), self.width, function() self:onClose() end, self)
    local notes = day.notes or { highlights = {}, bookmarks = {} }

    local summary = table.concat({
        Data.fmtDuration(day.seconds),
        Data.plural(day.pages, _("page"), _("pages")),
        Data.plural(day.books, _("book"), _("books")),
        Data.plural(#notes.highlights, _("highlight"), _("highlights")),
        Data.plural(#notes.bookmarks, _("bookmark"), _("bookmarks")),
    }, " · ")
    local content = VerticalGroup:new{
        align = "center",
        Theme.card(CenterContainer:new{
            dimen = Geom:new{ w = cardInner(self.inner_w), h = px(28) },
            text(summary, Theme.face("script", 15), { max_width = cardInner(self.inner_w) }),
        }, { radius = px(18) }),
        VerticalSpan:new{ width = gap },
    }
    local function add(w) table.insert(content, w) end
    local function room()
        local h = content:getSize().h
        content:resetLayout()
        return self.height - header:getSize().h - h - px(40)
    end

    -- Books
    add(section(_("Books I read ♡")))
    add(vspan(4))
    if day.books == 0 then
        add(muted(_("No reading this day ❀"), 16))
    end
    local row_h = px(64)
    for i = 1, math.min(MAX_BOOKS, day.books) do
        if i > 1 then add(vspan(6)) end
        add(self:bookRow(day.list[i], row_h))
    end
    if day.books > MAX_BOOKS then
        add(muted(string.format(_("+%d more %s"), day.books - MAX_BOOKS, Theme.open_heart), 14))
    end
    add(VerticalSpan:new{ width = gap })

    -- Bookmarks are one-liners, so reserve their room before the highlights.
    local bm_lines = math.min(#notes.bookmarks, 4)
    local line_h = muted("x", 15):getSize().h
    local bookmarks_h = (line_h + px(2)) * math.max(1, bm_lines) + line_h * 2 + gap

    add(section(_("Highlights ♥")))
    add(vspan(4))
    if #notes.highlights == 0 then
        add(muted(_("No highlights this day — just vibes ♡"), 16))
    else
        local shown = 0
        for i, h in ipairs(notes.highlights) do
            local card = self:highlightCard(h, 3)
            local card_h = card:getSize().h
            if card_h + px(6) > room() - bookmarks_h then break end
            if i > 1 then add(vspan(6)) end
            add(card)
            shown = i
        end
        if shown < #notes.highlights then
            add(muted(string.format(_("+%d more highlights %s"), #notes.highlights - shown, Theme.open_heart), 14))
        end
    end
    add(VerticalSpan:new{ width = gap })

    add(section(_("Bookmarks ☆")))
    add(vspan(4))
    if #notes.bookmarks == 0 then
        add(muted(_("No bookmarks this day ☆"), 16))
    else
        for i = 1, bm_lines do
            local b = notes.bookmarks[i]
            local parts = { Theme.star .. " " .. b.title }
            if b.page then parts[#parts + 1] = string.format(_("p. %d"), b.page) end
            if b.chapter then parts[#parts + 1] = b.chapter end
            parts[#parts + 1] = b.time
            add(text(table.concat(parts, " · "), Theme.face("script", 15), { max_width = self.inner_w }))
            add(vspan(2))
        end
        if #notes.bookmarks > bm_lines then
            add(muted(string.format(_("+%d more %s"), #notes.bookmarks - bm_lines, Theme.star), 14))
        end
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
            vspan(8),
            content,
        },
    }
end

function BlossomDay:onSwipe(_, ges)
    if ges.direction == "south" or ges.direction == "east" then return self:onClose() end
    return true
end

function BlossomDay:onClose()
    UIManager:close(self)
    return true
end

function BlossomDay:onCloseWidget()
    -- Cover blitbuffers belong to the dashboard; this only frees scaled copies.
    if self[1] then self[1]:free() end
    UIManager:setDirty(nil, "full")
end

return BlossomDay
