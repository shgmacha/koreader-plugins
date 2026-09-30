--[[--
Blossom's "tell me more" pages, opened by tapping a number in the reading garden:
a paged cover gallery for books, or paged lists for highlights and bookmarks.
--]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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
    kind = "gallery",  -- "gallery", "highlights" or "bookmarks"
    items = nil,
    gallery = nil,     -- function(books, avail_h) -> widget (gallery pages)
    empty_text = nil,
    page = 1,
    covers_fullscreen = true,
}

function BlossomMore:init()
    self.items = self.items or {}
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.inner_w = self.width - 2 * px(Theme.MARGIN)
    self.starts = { 1 } -- first item of each list page, found while paging forward
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
    self:build()
end

local function muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
end

function BlossomMore:pageCount()
    if self.kind == "gallery" then
        return math.max(1, math.ceil(#self.items / GALLERY_PER_PAGE))
    end
    return nil -- lists: only known once paged through
end

function BlossomMore:hasNext()
    if self.kind == "gallery" then return self.page < self:pageCount() end
    return self.starts[self.page + 1] ~= nil and self.starts[self.page + 1] <= #self.items
end

function BlossomMore:bookmarkRow(b)
    local first = {}
    if b.page then first[#first + 1] = string.format(_("p. %d"), b.page) end
    if b.chapter then first[#first + 1] = b.chapter end
    if #first == 0 then first[1] = _("bookmark") end
    return VerticalGroup:new{
        align = "left",
        text(Theme.star .. "  " .. table.concat(first, " · "), Theme.face("script", 16), { max_width = self.inner_w }),
        muted("     " .. b.title .. " · " .. (b.date or ""), 13, self.inner_w),
    }
end

function BlossomMore:quoteRow(h)
    local meta = { h.title }
    if h.page then meta[#meta + 1] = string.format(_("p. %d"), h.page) end
    meta[#meta + 1] = h.date
    return Theme.quote(h.text, table.concat(meta, " · "), h.note, self.inner_w, 4)
end

--- Fills one list page from self.starts[page], remembering where the next one begins.
function BlossomMore:listPage(avail_h)
    local group = VerticalGroup:new{ align = "left" }
    local i = self.starts[self.page]
    local gap = px(self.kind == "highlights" and 18 or 14)
    while i <= #self.items do
        local row = self.kind == "highlights" and self:quoteRow(self.items[i]) or self:bookmarkRow(self.items[i])
        local h = group:getSize().h
        group:resetLayout()
        local needed = row:getSize().h + (#group > 0 and gap or 0)
        if h + needed > avail_h and #group > 0 then
            row:free()
            break
        end
        if #group > 0 then table.insert(group, vspan(self.kind == "highlights" and 18 or 14)) end
        table.insert(group, row)
        i = i + 1
    end
    self.starts[self.page + 1] = i
    return group
end

function BlossomMore:buildFooter()
    local count = self:pageCount() or (not self:hasNext() and self.page or nil)
    local label = count and string.format("%d / %d", self.page, count) or tostring(self.page)
    local function arrow(glyph, enabled, fn)
        return Button:new{
            text = glyph,
            bordersize = 0,
            width = px(56),
            text_font_size = 24,
            enabled = enabled,
            callback = fn,
            show_parent = self,
        }
    end
    return VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            align = "center",
            arrow("‹", self.page > 1, function() self:onPrevPage() end),
            HorizontalSpan:new{ width = px(12) },
            text(label, Theme.face("script", 15), { color = Theme.soft_ink }),
            HorizontalSpan:new{ width = px(12) },
            arrow("›", self:hasNext(), function() self:onNextPage() end),
        },
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
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Theme.bg,
        bordersize = 0,
        padding = 0,
        OverlapGroup:new{
            dimen = full,
            VerticalGroup:new{
                align = "center",
                header,
                vspan(Theme.TOP_GAP),
                content,
            },
            BottomContainer:new{ dimen = full, self:buildFooter() },
        },
    }
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
