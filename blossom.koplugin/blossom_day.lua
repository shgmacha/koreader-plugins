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
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
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
}

function BlossomDay:init()
    Theme.initPage(self)
    self.inner_w = self.width - 2 * px(Theme.MARGIN)
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    Theme.addWindowGestures(self)
    self:build()
end

local function muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
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

function BlossomDay:quote(h, max_lines)
    local where = { h.title }
    if h.page then where[#where + 1] = string.format(_("p. %d"), h.page) end
    where[#where + 1] = h.time
    return Theme.quote(h.text, table.concat(where, " · "), h.note, self.inner_w, max_lines)
end

function BlossomDay:build()
    local day = self.day
    local gap = px(12)
    local d = select(3, Data.parseDate(day.date))
    local header = Theme.header(tostring(d), self.width, function() self:onClose() end, self, {
        back = true,
        title_size = 34,
        subtitle = Data.daySubtitle(day.date),
    })
    local notes = day.notes or { highlights = {}, bookmarks = {} }
    local header_h = header:getSize().h

    local content = VerticalGroup:new{ align = "center" }
    local function add(w) table.insert(content, w) end
    local function room()
        local h = content:getSize().h
        content:resetLayout()
        return self.height - header_h - h - px(48)
    end

    add(Theme.statStrip({
        { Data.fmtDuration(day.seconds), _("read") },
        { tostring(day.pages), day.pages == 1 and _("page") or _("pages") },
        { tostring(#notes.highlights), #notes.highlights == 1 and _("highlight") or _("highlights") },
        { tostring(#notes.bookmarks), #notes.bookmarks == 1 and _("bookmark") or _("bookmarks") },
    }, self.inner_w))
    add(VerticalSpan:new{ width = gap })

    add(Theme.rule(_("books I read"), self.inner_w))
    add(vspan(8))
    if day.books == 0 then
        add(muted(_("No reading this day ❀"), 16))
    else
        -- Books four at a time, with a pager when there are more.
        local pages = math.ceil(day.books / MAX_BOOKS)
        self.books_page = math.min(self.books_page or 1, pages)
        local slice = {}
        for i = (self.books_page - 1) * MAX_BOOKS + 1, math.min(day.books, self.books_page * MAX_BOOKS) do
            slice[#slice + 1] = day.list[i]
        end
        add(self:coverRow(slice))
        if pages > 1 then
            add(vspan(4))
            add(Theme.pager(self.books_page, pages,
                function() self.books_page = self.books_page - 1; self:refresh() end,
                function() self.books_page = self.books_page + 1; self:refresh() end))
        end
    end
    add(VerticalSpan:new{ width = gap })

    -- Highlights, then bookmarks, as one paged list; each section keeps its title.
    local items = {}
    for _, h in ipairs(notes.highlights) do items[#items + 1] = { section = "highlights", note = h } end
    for _, b in ipairs(notes.bookmarks) do items[#items + 1] = { section = "bookmarks", note = b } end
    local pager
    if #items == 0 then
        add(Theme.rule(_("notes"), self.inner_w))
        add(vspan(8))
        add(muted(_("No highlights or bookmarks — just quiet reading ♡"), 16, self.inner_w))
    else
        local avail = room() - px(50)
        local make_row = function(item, _idx, prev)
            local row = item.section == "highlights" and self:quote(item.note) or self:bookmarkRow(item.note)
            if item.section == "highlights" and row:getSize().h > avail - px(40) then
                -- a highlight taller than the page: cut to fit
                row:free()
                row = self:quote(item.note, math.max(2, floor((avail - px(110)) / (17 * 1.45))))
            end
            if prev and prev.section == item.section then return row end
            return VerticalGroup:new{
                align = "center",
                Theme.rule(item.section == "highlights" and _("highlights") or _("bookmarks"), self.inner_w),
                vspan(10),
                row,
            }
        end
        if not self.note_starts then
            self.note_starts = Theme.pageStarts(items, avail, make_row, px(14))
        end
        self.note_page = math.min(self.note_page or 1, #self.note_starts)
        add((Theme.fillPage(items, self.note_starts[self.note_page], avail, make_row, px(14))))
        if #self.note_starts > 1 then
            pager = Theme.pager(self.note_page, #self.note_starts,
                function() self:turnNotes(-1) end, function() self:turnNotes(1) end)
        end
    end

    if self[1] then self[1]:free() end
    self[1] = Theme.pageFrame(self,
        OverlapGroup:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            VerticalGroup:new{
                align = "center",
                header,
                vspan(Theme.TOP_GAP),
                content,
            },
            pager and BottomContainer:new{
                dimen = Geom:new{ w = self.width, h = self.height },
                VerticalGroup:new{ align = "center", pager, vspan(6) },
            } or nil,
        }
    )
end

function BlossomDay:bookmarkRow(b)
    local parts = {}
    if b.page then parts[#parts + 1] = string.format(_("p. %d"), b.page) end
    if b.chapter then parts[#parts + 1] = b.chapter end
    parts[#parts + 1] = b.title
    parts[#parts + 1] = b.time
    return text(Theme.star .. "  " .. table.concat(parts, " · "), Theme.face("script", 15), { max_width = self.inner_w })
end

function BlossomDay:refresh()
    self:build()
    UIManager:setDirty(self, "flashui")
end

function BlossomDay:turnNotes(delta)
    local page = (self.note_page or 1) + delta
    if page < 1 or page > #(self.note_starts or { 1 }) then return end
    self.note_page = page
    self:refresh()
end

function BlossomDay:onSwipe(_, ges)
    if ges.direction == "west" then self:turnNotes(1); return true end
    if ges.direction == "east" then
        if (self.note_page or 1) > 1 then self:turnNotes(-1); return true end
        return self:onClose()
    end
    if ges.direction == "south" then return self:onClose() end
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
