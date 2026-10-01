--[[--
This book, floating over the page: its Goodreads match, shelf, ♥ rating,
and finding another match.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("blossomreads_store")
local Theme = require("blossomreads_theme")
local View = require("blossomreads_view")

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

function Book:chip(label, on, callback, w)
    return View.tap(Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = w, h = px(30) },
        text(label, Theme.face(on and "bold" or "script", 15), { max_width = w }),
    }, {
        padding = px(4),
        bordersize = on and Theme.px(2) or 1,
        border_color = on and Theme.ink or Theme.accent,
        background = on and Theme.petal or Theme.card_bg,
        radius = px(15),
    }), callback)
end

function Book:content()
    local e = self:entry()
    local group = VerticalGroup:new{ align = "center" }
    if not (e and e.gid) then
        table.insert(group, vspan(20))
        table.insert(group, text(Theme.flower, Theme.face("ui", 40), { color = Theme.soft_ink }))
        table.insert(group, vspan(8))
        table.insert(group, muted(_("Not linked to Goodreads yet ♡"), 17, self.inner_w))
        table.insert(group, vspan(16))
        table.insert(group, self:chip(_("Find on Goodreads"), true, function() self:find() end, px(220)))
        return group
    end
    local now = self.plugin:liveProgress() or {}
    local cover = View.bookCover(self.file, e.gid, px(80), px(120))
    local info_w = self.inner_w - px(96)
    local info = VerticalGroup:new{
        align = "left",
        text(e.title or "", Theme.face("script_bold", 20), { max_width = info_w }),
        muted(e.author or "", 15, info_w),
        vspan(8),
        text(now.pct and T(_("Read %1%"), now.pct) or "", Theme.face("script", 16)),
    }
    if e.synced_at then
        table.insert(info, muted(T(_("synced %1"), os.date("%b %d, %H:%M", e.synced_at)), 13, info_w))
    end
    table.insert(group, HorizontalGroup:new{ align = "top", cover, HorizontalSpan:new{ width = px(16) }, info })
    table.insert(group, vspan(18))

    -- Shelf chips: two per row.
    table.insert(group, Theme.rule(_("my shelf"), self.inner_w))
    table.insert(group, vspan(8))
    local current = e.pinned_shelf or e.pushed_shelf
    local chip_w = math.floor((self.inner_w - px(30)) / 2)
    for i = 1, #SHELVES, 2 do
        local row = HorizontalGroup:new{ align = "center" }
        for j = i, i + 1 do
            local slug = SHELVES[j]
            if j > i then table.insert(row, HorizontalSpan:new{ width = px(14) }) end
            table.insert(row, self:chip(SHORT[slug], current == slug, function() self:setShelf(slug) end, chip_w))
        end
        table.insert(group, row)
        table.insert(group, vspan(8))
    end

    -- Rating: tap a heart.
    table.insert(group, vspan(6))
    table.insert(group, Theme.rule(_("my rating"), self.inner_w))
    table.insert(group, vspan(6))
    local hearts = HorizontalGroup:new{ align = "center" }
    for n = 1, 5 do
        if n > 1 then table.insert(hearts, HorizontalSpan:new{ width = px(10) }) end
        local glyph = n <= (e.rating or 0) and Theme.heart or Theme.open_heart
        table.insert(hearts, View.tap(text(glyph, Theme.face("ui", 30)), function() self:rate(n) end))
    end
    table.insert(group, hearts)
    table.insert(group, vspan(18))
    table.insert(group, HorizontalGroup:new{
        align = "center",
        View.tap(muted(_("Not this book? Find another"), 15), function() self:find(true) end),
        HorizontalSpan:new{ width = px(16) },
        View.tap(muted(_("Unlink"), 15), function() self:unlink() end),
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
    require("blossomreads_list").pick(p, found.ranked, function(book)
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
