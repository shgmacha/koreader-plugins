--[[--
Blossom's book detail page: a big cover, progress ribbon and six little
stat cards for one book. Shown on top of the dashboard; covers come from
the dashboard's cache through the `art` callback.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
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
local text, vspan = Theme.text, Theme.vspan

local BlossomDetail = InputContainer:extend{
    book = nil, -- Data.bookDetail result
    art = nil,     -- function(book, w, h, fill) -> cover widget
    aspect = nil,  -- function(book) -> cover height / width, or nil without a cover
    covers_fullscreen = true,
}

function BlossomDetail:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.inner_w = self.width - 2 * px(Theme.MARGIN)
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

--- The little frameless stats: glyph, value, label.
function BlossomDetail:statValues()
    local b = self.book
    return {
        { Theme.open_heart, Data.fmtDuration(b.seconds), _("time together") },
        { Theme.icon("rose_bloom", 18), tostring(b.days), b.days == 1 and _("reading day") or _("reading days") },
        { "✧", b.speed and tostring(b.speed) or "—", _("pages per hour") },
        { "☾", b.finished and "—" or (b.time_left and Data.fmtDuration(b.time_left) or "—"),
          b.finished and _("all read!") or _("left to read") },
        { Theme.heart, tostring(#(b.highlight_list or {})), #(b.highlight_list or {}) == 1 and _("highlight") or _("highlights") },
        { Theme.star, tostring(b.bookmark_count or 0), b.bookmark_count == 1 and _("bookmark") or _("bookmarks") },
    }
end

function BlossomDetail:build()
    local b = self.book
    local gap = px(22)
    local header = Theme.header(_("Book details"), self.width, function() self:onClose() end, self, { back = true })

    -- Cover beside: title, author, snippet, wavy progress, "66% read · 250 of 380 pages".
    local ratio = (self.aspect and self.aspect(b)) or 1.45
    local cover_w = floor(self.inner_w * 0.36)
    local max_h = floor(self.height * 0.3)
    if floor(cover_w * ratio) > max_h then cover_w = floor(max_h / ratio) end
    local cover_h = floor((cover_w - 2 * Size.border.thin) * ratio)
    local info_w = self.inner_w - cover_w - gap
    local pct = floor(b.progress * 100 + 0.5)

    local info = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = b.title,
            face = Theme.face("script_bold", 21),
            width = info_w,
            bgcolor = Theme.bg,
        },
        vspan(2),
        text(b.authors ~= "" and b.authors or " ", Theme.face("script", 16),
            { color = Theme.soft_ink, max_width = info_w }),
    }
    if b.snippet then
        table.insert(info, vspan(12))
        -- Natural height, at most 5 lines.
        local function snippet(height)
            return TextBoxWidget:new{
                text = b.snippet,
                face = Theme.face("script", 14),
                fgcolor = Theme.soft_ink,
                width = info_w,
                height = height,
                height_overflow_show_ellipsis = true,
                bgcolor = Theme.bg,
            }
        end
        local box = snippet()
        local max_snippet_h = floor(5 * Theme.face("script", 14).size * 1.45)
        if box:getSize().h > max_snippet_h then
            box:free()
            box = snippet(max_snippet_h)
        end
        table.insert(info, box)
    end
    table.insert(info, vspan(14))
    table.insert(info, Theme.wave(b.progress, info_w))
    table.insert(info, vspan(4))
    local pages = b.total_pages > 0
        and string.format(_("%d of %d pages"), math.min(b.read_pages, b.total_pages), b.total_pages) or nil
    local progress_line = b.finished and _("finished") or string.format(_("%d%% read"), pct)
    if pages then progress_line = progress_line .. " · " .. pages end
    local progress = text(progress_line, Theme.face("script", 15), { max_width = info_w - px(30) })
    table.insert(info, b.finished and Theme.withBow(progress, 20, "left") or progress)

    -- The cover fills a frame shaped like itself.
    local cover = Theme.RoundedFrame:new{
        radius = px(10),
        bordersize = Size.border.thin,
        color = Theme.accent,
        background = Theme.bg,
        outside = Theme.bg,
        self.art(b, cover_w - 2 * Size.border.thin, cover_h, true),
    }
    local top = HorizontalGroup:new{ align = "top", cover, HorizontalSpan:new{ width = gap }, info }

    local content = VerticalGroup:new{
        align = "center",
        top,
        VerticalSpan:new{ width = gap },
        Theme.rule(_("my reading"), self.inner_w),
        vspan(14),
        Theme.statGrid(self:statValues(), self.inner_w, 3, { row_gap = 20 }),
        vspan(14),
        text(string.format(_("first read %s · last read %s"), b.first or "—", b.last or "—"),
            Theme.face("script", 13), { color = Theme.soft_ink, max_width = self.inner_w }),
        VerticalSpan:new{ width = gap },
        Theme.rule(_("my highlights"), self.inner_w),
        vspan(16),
    }
    local function room()
        local h = content:getSize().h
        content:resetLayout()
        return self.height - header:getSize().h - h - px(48)
    end
    local list = b.highlight_list or {}
    if #list == 0 then
        table.insert(content, text(_("No highlights yet — the best is still ahead ♡"), Theme.face("script", 15),
            { color = Theme.soft_ink, max_width = self.inner_w }))
    else
        local shown = 0
        for i, h in ipairs(list) do
            local meta = {}
            if h.page then meta[#meta + 1] = string.format(_("p. %d"), h.page) end
            if h.chapter then meta[#meta + 1] = h.chapter end
            meta[#meta + 1] = h.date
            local q = Theme.quote(h.text, table.concat(meta, " · "), h.note, self.inner_w, 3)
            local more_h = i < #list and px(22) or 0
            if q:getSize().h + px(18) + more_h > room() and shown == 0 then
                -- Always show at least one: a shorter version of the first highlight.
                q:free()
                q = Theme.quote(h.text, table.concat(meta, " · "), nil, self.inner_w, 2)
            end
            if q:getSize().h + px(18) + more_h > room() and shown > 0 then q:free(); break end
            if i > 1 then table.insert(content, vspan(18)) end
            table.insert(content, q)
            shown = i
        end
        if shown < #list then
            table.insert(content, vspan(6))
            table.insert(content, text(string.format(_("+%d more highlights %s"), #list - shown, Theme.open_heart),
                Theme.face("script", 14), { color = Theme.soft_ink }))
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
            vspan(Theme.TOP_GAP),
            content,
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
