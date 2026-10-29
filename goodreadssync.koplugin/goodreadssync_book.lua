--[[--
This book, floating over the page: its Goodreads match, shelf, star rating,
and finding another match.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("goodreadssync_store")
local Theme = require("goodreadssync_theme")
local View = require("goodreadssync_view")

local px, text, vspan, muted = Theme.px, Theme.text, Theme.vspan, View.muted

local Book = View.Page:extend{}

local SHELVES = { "to-read", "currently-reading", "read", "did-not-finish" }
local SHORT = { ["to-read"] = _("Want to Read"), ["currently-reading"] = _("Reading"),
    ["read"] = _("Read"), ["did-not-finish"] = _("DNF") }

function Book:entry()
    return Store.open("books"):get(self.file)
end

function Book:save(fields)
    local store = Store.open("books")
    local e = store:get(self.file)
    for k, v in pairs(fields) do e[k] = v end
    store:set(self.file, e)
    store:flush()
end

-- A shelf button; the current shelf is filled espresso.
function Book:chip(label, on, callback, w)
    return View.tap(View.chip(label, w, px(30), on), callback)
end

function Book:content()
    local e = self:entry()
    local group = VerticalGroup:new{ align = "center" }
    if not (e and e.gid) then
        table.insert(group, vspan(30))
        table.insert(group, muted(_("This book isn't linked to Goodreads yet."), 16, self.inner_w))
        table.insert(group, vspan(16))
        table.insert(group, self:chip(_("Find on Goodreads"), true, function() self:find() end, px(220)))
        return group
    end
    local now = self.plugin:liveProgress() or {}
    local cover = View.bookCover(self.file, e.gid, px(76), px(114), e.title)
    local info_w = self.inner_w - px(92)
    local info = VerticalGroup:new{
        align = "left",
        text(e.title or "", Theme.face("bold", 18), { max_width = info_w }),
        muted(e.author or "", 14, info_w),
        vspan(8),
        text(now.pct and T(_("%1% read"), now.pct) or "", Theme.face("regular", 15)),
    }
    if now.pct then
        table.insert(info, vspan(4))
        table.insert(info, Theme.progressBar(now.pct / 100, math.min(info_w, px(200))))
    end
    if e.synced_at then
        table.insert(info, vspan(4))
        table.insert(info, muted(T(_("Synced %1"), os.date("%b %d, %H:%M", e.synced_at)), 12, info_w))
    end
    table.insert(group, HorizontalGroup:new{ align = "top", cover, HorizontalSpan:new{ width = px(16) }, info })
    table.insert(group, vspan(18))

    -- Shelf: two buttons per row, in a section card.
    local current = e.pinned_shelf or e.pushed_shelf
    local inner = Theme.sectionInner(self.inner_w)
    local chip_w = math.floor((inner - px(12)) / 2) - 2 * px(3)
    local shelf_rows = VerticalGroup:new{ align = "left" }
    for i = 1, #SHELVES, 2 do
        local row = HorizontalGroup:new{ align = "center" }
        for j = i, i + 1 do
            local slug = SHELVES[j]
            if j > i then table.insert(row, HorizontalSpan:new{ width = px(12) }) end
            table.insert(row, self:chip(SHORT[slug], current == slug, function() self:setShelf(slug) end, chip_w))
        end
        if i > 1 then table.insert(shelf_rows, vspan(8)) end
        table.insert(shelf_rows, row)
    end
    table.insert(group, Theme.section(_("Shelf"), shelf_rows, self.inner_w))
    table.insert(group, vspan(12))

    -- Rating: tap a star.
    local stars = HorizontalGroup:new{ align = "center" }
    for n = 1, 5 do
        if n > 1 then table.insert(stars, HorizontalSpan:new{ width = px(12) }) end
        local glyph = n <= (e.rating or 0) and Theme.star or Theme.empty_star
        table.insert(stars, View.tap(text(glyph, Theme.face("regular", 30)), function() self:rate(n) end))
    end
    table.insert(group, Theme.section(_("Rating"), CenterContainer:new{
        dimen = Geom:new{ w = inner, h = stars:getSize().h }, stars }, self.inner_w))
    table.insert(group, vspan(16))
    table.insert(group, HorizontalGroup:new{
        align = "center",
        View.tap(View.chip(_("Wrong book? Find another"), px(210)), function() self:find(true) end),
        HorizontalSpan:new{ width = px(12) },
        View.tap(View.chip(_("Unlink"), px(80)), function() self:unlink() end),
    })
    return group
end

function Book:setShelf(slug)
    local e = self:entry()
    if not self.plugin:busy(function(api) return api:setShelf(e.gid, slug) end) then return end
    -- Picked by hand: automatic "Currently Reading" stays off for this book.
    self:save{ pushed_shelf = slug, pinned_shelf = slug ~= "read" and slug or nil, synced_at = os.time() }
    self:refresh()
end

function Book:rate(n)
    local e = self:entry()
    if not self.plugin:busy(function(api) return api:rate(e.gid, n) end) then return end
    self:save{ rating = n }
    self:refresh()
end

function Book:unlink()
    self.plugin:unlinkBook(self.file)
    self:refresh()
end

-- Find matches; link a sure one, otherwise let the reader pick.
function Book:find(always_pick)
    local p = self.plugin
    local found = p:busy(function()
        local m, h, r, err = p:findMatches(self.file)
        if err then return nil, err end
        return { match = m, how = h, ranked = r or {} }
    end)
    if not found then return end -- error already shown
    if found.match and not always_pick then
        p:linkBook(self.file, found.match, found.how)
        self:refresh()
        return
    end
    require("goodreadssync_list").pick(p, found.ranked, function(book)
        p:linkBook(self.file, book, "manual")
        self:refresh()
    end)
end

local M = {}

function M.show(plugin, file)
    return Book:new{ plugin = plugin, file = file, title = _("This book") }:show()
end

M.Book = Book
return M
