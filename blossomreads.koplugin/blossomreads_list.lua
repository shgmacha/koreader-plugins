--[[--
Lists of Goodreads books as Blossom pages: a shelf, search results, or
matches to pick from. Covers for the page being shown are fetched quietly
after it appears.
--]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local Covers = require("blossomreads_covers")
local Theme = require("blossomreads_theme")
local View = require("blossomreads_view")

local px, text, vspan, muted = Theme.px, Theme.text, Theme.vspan, View.muted

local ROW_H, GAP = 78, 12

local List = View.Page:extend{
    items = nil,     -- { gid, title, author, cover, rating, score }
    on_pick = nil,   -- function(book)
    more = nil,      -- function() -> more items or nil (next Goodreads page)
    empty = nil,
}

function List:perPage(avail)
    return math.max(1, math.floor((avail + px(GAP)) / px(ROW_H + GAP)))
end

function List:row(b)
    local info_w = self.inner_w - px(66)
    local info = VerticalGroup:new{
        align = "left",
        text(b.title or _("Untitled"), Theme.face("script_bold", 16), { max_width = info_w }),
        muted(b.author or "", 14, info_w),
    }
    if b.rating then
        table.insert(info, text(View.hearts(b.rating), Theme.face("ui", 13), { color = Theme.soft_ink }))
    elseif b.score then
        table.insert(info, muted(T(_("%1% match"), b.score), 13))
    end
    return View.tap(HorizontalGroup:new{
        align = "center",
        View.cover(Covers.cached(b.gid), px(50), px(ROW_H)),
        HorizontalSpan:new{ width = px(14) },
        info,
    }, function() self:pick(b) end)
end

function List:content(avail)
    local items = self.items or {}
    local group = VerticalGroup:new{ align = "left" }
    if #items == 0 then
        table.insert(group, vspan(40))
        table.insert(group, muted(self.empty or _("Nothing here yet ❀"), 17, self.inner_w))
        return group
    end
    local per = self:perPage(avail)
    self.per_page = per
    self.pages = math.max(1, math.ceil(#items / per)) + (self.more and 1 or 0)
    local from = (self.page - 1) * per + 1
    for i = from, math.min(#items, from + per - 1) do
        if i > from then table.insert(group, vspan(GAP)) end
        table.insert(group, self:row(items[i]))
    end
    -- Lists line up on the left margin, as in Blossom.
    return LeftContainer:new{ dimen = Geom:new{ w = self.inner_w, h = group:getSize().h }, group }
end

function List:visible()
    local per = self.per_page or 1
    local out, from = {}, (self.page - 1) * per + 1
    for i = from, math.min(#self.items, from + per - 1) do out[#out + 1] = self.items[i] end
    return out
end

-- Fetch the shown page's missing covers after it's on screen.
function List:loadCovers()
    local missing = {}
    for _i, b in ipairs(self:visible()) do
        if b.cover and not Covers.cached(b.gid) then missing[#missing + 1] = b end
    end
    if #missing == 0 then return end
    UIManager:scheduleIn(0.2, function()
        for _i, b in ipairs(missing) do Covers.get(b.gid, b.cover, self.plugin.transport) end
        if self.alive then self:refresh() end
    end)
end

function List:show()
    self.alive = true
    View.Page.show(self)
    self:loadCovers()
    return self
end

function List:onNextPage()
    -- Past the last loaded page: fetch the next Goodreads page first.
    local per = self.per_page or 1
    if self.more and self.page >= math.ceil(#self.items / per) then
        local before = #self.items
        local extra, has_more = self.more()
        if not has_more then self.more = nil end
        for _i, b in ipairs(extra or {}) do table.insert(self.items, b) end
        -- New books first fill the rest of this page.
        if before % per ~= 0 or #self.items == before then
            self:refresh()
            self:loadCovers()
            return true
        end
    end
    View.Page.onNextPage(self)
    self:loadCovers()
    return true
end

function List:onPrevPage()
    View.Page.onPrevPage(self)
    self:loadCovers()
    return true
end

function List:onCloseWidget()
    self.alive = false
    View.Page.onCloseWidget(self)
end

function List:pick(book)
    if self.on_pick then
        self:onClose()
        self.on_pick(book)
        return
    end
    self:chooseShelf(book)
end

-- Put a book on one of your shelves.
function List:chooseShelf(book)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    local slugs = { "to-read", "currently-reading", "read", "did-not-finish" }
    for _i, s in ipairs((self.plugin:getSetting("shelves") or {}).list or {}) do
        if s.custom then slugs[#slugs + 1] = s.slug end
    end
    for _i, slug in ipairs(slugs) do
        buttons[#buttons + 1] = { {
            text = View.shelfName(slug),
            callback = function()
                UIManager:close(dialog)
                if self.plugin:busy(function(api) return api:setShelf(book.gid, slug) end) then
                    self.plugin:card(T(_("Added to %1 ♡"), View.shelfName(slug)), 2)
                end
            end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = book.title or "", buttons = buttons }
    UIManager:show(dialog)
end

local M = { List = List }

function M.shelf(plugin, slug)
    local page = 1
    local function load()
        local got = plugin:busy(function(api)
            local list, more_or_err = api:shelfBooks(slug, page)
            if not list then return nil, more_or_err end
            return { list = list, more = more_or_err }
        end)
        return got
    end
    local first = load()
    if not first then return end
    return List:new{
        plugin = plugin, back = true, items = first.list,
        title = View.shelfName(slug), empty = _("This shelf is empty ❀"),
        more = first.more and function()
            page = page + 1
            local got = load()
            if not got then return nil, true end -- failed: keep offering more
            return got.list, got.more
        end or nil,
    }:show()
end

function M.search(plugin, query)
    local list = plugin:busy(function(api) return api:search(query) end)
    if not list then return end
    return List:new{
        plugin = plugin, back = true, items = list,
        title = _("Found on Goodreads"), subtitle = query, empty = _("No books found ☆"),
    }:show()
end

function M.pick(plugin, items, on_pick)
    return List:new{
        plugin = plugin, back = true, items = items, on_pick = on_pick,
        title = _("Which book is it?"), empty = _("No matches found ☆"),
    }:show()
end

return M
