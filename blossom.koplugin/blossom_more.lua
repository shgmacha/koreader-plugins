--[[--
Blossom's "tell me more" pages, opened by tapping a number in the reading garden:
a paged cover gallery for books, or paged lists for highlights and bookmarks.
--]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local _ = require("gettext")

local Theme = require("blossom_theme")

local px = Theme.px
local text, vspan = Theme.text, Theme.vspan

local GALLERY_PER_PAGE = 8

local BlossomMore = InputContainer:extend{
    title = nil,
    subtitle = nil,
    kind = "gallery",  -- "gallery", "highlights" or "bookmarks" (bookmarks may mix in highlights)
    items = nil,
    gallery = nil,     -- function(books, avail_h) -> widget (gallery pages)
    empty_text = nil,
    page = 1,
}

function BlossomMore:init()
    self.items = self.items or {}
    Theme.initPage(self)
    self.inner_w = self.width - 2 * px(Theme.MARGIN)
    self.starts = { 1 } -- first item of each list page
    if Device:isTouchDevice() then
        self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    end
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    Theme.addWindowGestures(self)
    self:build()
end

local function muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
end

function BlossomMore:pageCount()
    if self.kind == "gallery" then
        return math.max(1, math.ceil(#self.items / GALLERY_PER_PAGE))
    end
    return self.starts and #self.starts or 1
end

function BlossomMore:hasNext()
    return self.page < self:pageCount()
end

function BlossomMore:bookmarkRow(b)
    local first = {}
    if b.page then first[#first + 1] = string.format(_("p. %d"), b.page) end
    if b.chapter then first[#first + 1] = b.chapter end
    if #first == 0 then first[1] = _("bookmark") end
    return VerticalGroup:new{
        align = "left",
        text(Theme.star .. "  " .. table.concat(first, " · "), Theme.face("script", 15), { max_width = self.inner_w }),
        muted("     " .. b.title .. " · " .. (b.date or ""), 12, self.inner_w),
    }
end

function BlossomMore:quoteRow(h)
    local meta = { h.title }
    if h.page then meta[#meta + 1] = string.format(_("p. %d"), h.page) end
    meta[#meta + 1] = h.date
    return Theme.quote(h.text, table.concat(meta, " · "), h.note, self.inner_w, 4, 15)
end

function BlossomMore:makeRow(item)
    return (self.kind == "highlights" or item.kind == "highlight") and self:quoteRow(item) or self:bookmarkRow(item)
end

--- One list page; all page breaks are worked out the first time, so the pager knows the count.
function BlossomMore:listPage(avail_h)
    local gap = px(self.kind == "highlights" and 16 or 12)
    local make_row = function(item) return self:makeRow(item) end
    if not self.list_starts_done then
        self.starts = Theme.pageStarts(self.items, avail_h, make_row, gap)
        self.list_starts_done = true
    end
    return (Theme.fillPage(self.items, self.starts[self.page], avail_h, make_row, gap))
end

function BlossomMore:buildFooter()
    if self:pageCount() <= 1 then return VerticalGroup:new{ vspan(6) } end
    return VerticalGroup:new{
        align = "center",
        Theme.pager(self.page, self:pageCount(), function() self:onPrevPage() end, function() self:onNextPage() end),
        vspan(6),
    }
end

function BlossomMore:build()
    local header = Theme.header(self.title, self.width, function() self:onClose() end, self, { back = true })
    local reserve = px(56) -- room for the page footer
    local avail = self.height - header:getSize().h - px(Theme.TOP_GAP) - reserve - px(16)
    local content = VerticalGroup:new{ align = "center" }
    if self.subtitle then
        table.insert(content, muted(self.subtitle, 16, self.inner_w))
        table.insert(content, vspan(16))
        avail = avail - content:getSize().h
        content:resetLayout()
    end
    if #self.items == 0 then
        table.insert(content, vspan(40))
        table.insert(content, muted(self.empty_text or _("Nothing here yet ❀"), 18, self.inner_w))
    elseif self.kind == "gallery" then
        local from = (self.page - 1) * GALLERY_PER_PAGE + 1
        local slice = {}
        for i = from, math.min(#self.items, from + GALLERY_PER_PAGE - 1) do slice[#slice + 1] = self.items[i] end
        table.insert(content, self.gallery(slice, avail))
    else
        -- Lists line up on the left margin.
        local list = self:listPage(avail)
        table.insert(content, LeftContainer:new{ dimen = Geom:new{ w = self.inner_w, h = list:getSize().h }, list })
    end

    if self[1] then self[1]:free() end
    local full = Geom:new{ w = self.width, h = self.height }
    self[1] = Theme.pageFrame(self,
        OverlapGroup:new{
            dimen = full,
            VerticalGroup:new{
                align = "center",
                header,
                vspan(Theme.TOP_GAP),
                content,
            },
            BottomContainer:new{ dimen = full, self:buildFooter() },
        }
    )
end

function BlossomMore:refresh()
    self:build()
    UIManager:setDirty(self, "flashui")
end

function BlossomMore:onNextPage()
    if self:hasNext() then
        self.page = self.page + 1
        self:refresh()
    end
    return true
end

function BlossomMore:onPrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:refresh()
    end
    return true
end

function BlossomMore:onSwipe(_, ges)
    if ges.direction == "west" then return self:onNextPage() end
    if ges.direction == "east" then return self:onPrevPage() end
    if ges.direction == "south" then return self:onClose() end
    return true
end

function BlossomMore:onClose()
    UIManager:close(self)
    return true
end

function BlossomMore:onCloseWidget()
    -- Cover blitbuffers belong to the dashboard; this only frees scaled copies.
    if self[1] then self[1]:free() end
    UIManager:setDirty(nil, "full")
end

return BlossomMore
