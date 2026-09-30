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
local LineWidget = require("ui/widget/linewidget")
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

local MAX_BOOKS = 4

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

local function muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
end

--- Borderless soft strip of little stats: value over label.
function BlossomDay:statStrip(items)
    local inner = cardInner(self.inner_w)
    local col_w = floor(inner / #items)
    local row = HorizontalGroup:new{ align = "center" }
    for _, item in ipairs(items) do
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = px(52) },
            VerticalGroup:new{
                align = "center",
                text(item[1], Theme.face("bold", 18), { max_width = col_w }),
                muted(item[2], 14, col_w),
            },
        })
    end
    return Theme.card(row, { bordersize = 0, radius = px(18) })
end

--- Covers side by side with the time read that day underneath.
function BlossomDay:coverRow(books)
    local gap = px(14)
    local n = math.min(MAX_BOOKS, #books)
    local cover_w = math.min(px(92), floor((self.inner_w - gap * (MAX_BOOKS - 1)) / MAX_BOOKS))
    local cover_h = floor(cover_w * 1.45)
    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, n do
        local b = books[i]
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local caption = text(Data.fmtDuration(b.seconds), Theme.face("script", 15), { max_width = cover_w })
        if b.finished then caption = Theme.withBow(caption, 16, "left") end
        table.insert(row, self.tappable(VerticalGroup:new{
            align = "center",
            self.art(b, cover_w, cover_h),
            vspan(4),
            caption,
        }, b))
    end
    return row
end

--- A quote with a soft bar on its left: “text”, then book · page · time, then the note.
function BlossomDay:quote(h, max_lines)
    local bar_w, pad = px(3), px(12)
    local width = self.inner_w - bar_w - pad
    local face = Theme.face("script", 17)
    local function box(height)
        return TextBoxWidget:new{
            text = "“" .. (h.text or "") .. "”",
            face = face,
            width = width,
            height = height,
            height_overflow_show_ellipsis = true,
            bgcolor = Theme.bg,
        }
    end
    -- Natural height for short quotes; long ones stop at max_lines with an ellipsis.
    local quote = box()
    local max_h = floor(max_lines * face.size * 1.45)
    if quote:getSize().h > max_h then
        quote:free()
        quote = box(max_h)
    end
    local where = { h.title }
    if h.page then where[#where + 1] = string.format(_("p. %d"), h.page) end
    where[#where + 1] = h.time
    local body = VerticalGroup:new{
        align = "left",
        quote,
        vspan(2),
        muted(table.concat(where, " · "), 13, width),
    }
    if h.note then
        table.insert(body, vspan(2))
        table.insert(body, text("✎ " .. h.note, Theme.face("script", 15), { max_width = width }))
    end
    local bar = LineWidget:new{
        background = Theme.shades[3],
        dimen = Geom:new{ w = bar_w, h = body:getSize().h },
    }
    body:resetLayout()
    return HorizontalGroup:new{ align = "top", bar, HorizontalSpan:new{ width = pad }, body }
end

function BlossomDay:build()
    local day = self.day
    local gap = px(12)
    local d = select(3, Data.parseDate(day.date))
    local header = Theme.header(tostring(d), self.width, function() self:onClose() end, self, {
        title_size = 40,
        subtitle = Data.daySubtitle(day.date),
    })
    local notes = day.notes or { highlights = {}, bookmarks = {} }
    local header_h = header:getSize().h

    local content = VerticalGroup:new{ align = "center" }
    local function add(w) table.insert(content, w) end
    local function room()
        local h = content:getSize().h
        content:resetLayout()
        return self.height - header_h - h - px(24)
    end

    add(self:statStrip({
        { Data.fmtDuration(day.seconds), _("read") },
        { tostring(day.pages), day.pages == 1 and _("page") or _("pages") },
        { tostring(#notes.highlights), #notes.highlights == 1 and _("highlight") or _("highlights") },
        { tostring(#notes.bookmarks), #notes.bookmarks == 1 and _("bookmark") or _("bookmarks") },
    }))
    add(VerticalSpan:new{ width = gap })

    add(Theme.rule(_("books I read"), self.inner_w))
    add(vspan(8))
    if day.books == 0 then
        add(muted(_("No reading this day ❀"), 16))
    else
        add(self:coverRow(day.list))
        if day.books > MAX_BOOKS then
            add(muted(string.format(_("+%d more %s"), day.books - MAX_BOOKS, Theme.open_heart), 14))
        end
    end
    add(VerticalSpan:new{ width = gap })

    if #notes.highlights == 0 and #notes.bookmarks == 0 then
        add(Theme.rule(_("notes"), self.inner_w))
        add(vspan(8))
        add(muted(_("No highlights or bookmarks — just quiet reading ♡"), 16, self.inner_w))
    end

    -- Bookmarks are one-liners, so keep their room before adding highlights.
    local bm_lines = math.min(#notes.bookmarks, 3)
    local line_h = muted("x", 15):getSize().h
    local bookmarks_h = #notes.bookmarks > 0 and (line_h * (bm_lines + 2) + gap * 2) or 0

    if #notes.highlights > 0 then
        add(Theme.rule(_("highlights"), self.inner_w))
        add(vspan(10))
        local shown = 0
        for i, h in ipairs(notes.highlights) do
            local q = self:quote(h, 4)
            if q:getSize().h + px(14) > room() - bookmarks_h then break end
            if i > 1 then add(vspan(14)) end
            add(q)
            shown = i
        end
        if shown < #notes.highlights then
            add(vspan(6))
            add(muted(string.format(_("+%d more highlights %s"), #notes.highlights - shown, Theme.open_heart), 14))
        end
        add(VerticalSpan:new{ width = gap })
    end

    if #notes.bookmarks > 0 then
        add(Theme.rule(_("bookmarks"), self.inner_w))
        add(vspan(8))
        for i = 1, bm_lines do
            local b = notes.bookmarks[i]
            local parts = {}
            if b.page then parts[#parts + 1] = string.format(_("p. %d"), b.page) end
            if b.chapter then parts[#parts + 1] = b.chapter end
            parts[#parts + 1] = b.title
            parts[#parts + 1] = b.time
            add(text(Theme.star .. "  " .. table.concat(parts, " · "), Theme.face("script", 15),
                { max_width = self.inner_w }))
            add(vspan(4))
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
            vspan(10),
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
