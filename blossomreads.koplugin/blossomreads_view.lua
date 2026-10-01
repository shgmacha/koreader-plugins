--[[--
Blossom Reads screens: a shared floating page (Page) and the home page —
this book, the Goodreads reading challenge, your shelves and search.
--]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local Covers = require("blossomreads_covers")
local Store = require("blossomreads_store")
local Theme = require("blossomreads_theme")

local px, text, vspan = Theme.px, Theme.text, Theme.vspan

local View = {}

--------------------------------------------------------------------------------
-- Page: a floating Blossom page. Subclasses implement content(avail_h).
--------------------------------------------------------------------------------

local Page = InputContainer:extend{
    title = "",
    subtitle = nil,
    back = false,
    page = 1,
    pages = 1,
}
View.Page = Page

function Page:init()
    Theme.initPage(self)
    self.inner_w = self.width - 2 * px(Theme.MARGIN)
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

function Page:footer()
    if self.pages <= 1 then return nil end
    return VerticalGroup:new{
        align = "center",
        Theme.pager(self.page, self.pages, function() self:onPrevPage() end, function() self:onNextPage() end),
        vspan(6),
    }
end

function Page:build()
    local header = Theme.header(self.title, self.width, function() self:onClose() end, self,
        { back = self.back, subtitle = self.subtitle })
    local avail = self.height - header:getSize().h - px(Theme.TOP_GAP) - px(72)
    local content = self:content(avail)
    if self[1] then self[1]:free() end
    local full = Geom:new{ w = self.width, h = self.height }
    local layers = OverlapGroup:new{
        dimen = full,
        VerticalGroup:new{ align = "center", header, vspan(Theme.TOP_GAP), content },
    }
    local footer = self:footer()
    if footer then table.insert(layers, BottomContainer:new{ dimen = full, footer }) end
    self[1] = Theme.pageFrame(self, layers)
end

function Page:refresh()
    self:build()
    UIManager:setDirty(self, "flashui")
end

function Page:show()
    Theme.showPage(self)
    return self
end

function Page:onNextPage()
    if self.page < self.pages then
        self.page = self.page + 1
        self:refresh()
    end
    return true
end

function Page:onPrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:refresh()
    end
    return true
end

function Page:onSwipe(_, ges)
    local d = ges and ges.direction
    if d == "west" then return self:onNextPage() end
    if d == "east" then
        if self.page == 1 and self.back then return self:onClose() end
        return self:onPrevPage()
    end
    if d == "south" then return self:onClose() end
    return true
end

function Page:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Page:onCloseWidget()
    if self[1] then self[1]:free() end
    UIManager:setDirty(nil, "full")
end

--------------------------------------------------------------------------------
-- Shared bits
--------------------------------------------------------------------------------

function View.muted(str, size, max_width)
    return text(str, Theme.face("script", size or 15), { color = Theme.soft_ink, max_width = max_width })
end
local muted = View.muted

function View.tap(widget, callback)
    return Theme.Tappable:new{ callback = callback, widget }
end

-- A cover from a file, fitted into w×h, or a soft placeholder tile with a flower.
function View.cover(file, w, h)
    if file then
        return ImageWidget:new{ file = file, width = w, height = h, scale_factor = 0 }
    end
    return Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = w - 2, h = h - 2 },
        text(Theme.flower, Theme.face("ui", 22), { color = Theme.soft_ink }),
    }, { bordersize = 0, padding = 0, background = Theme.petal, radius = px(6) })
end

-- The book's own cover from KOReader when Goodreads' isn't downloaded yet.
function View.bookCover(file, gid, w, h)
    local cached = Covers.cached(gid)
    if not cached and file then
        local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
        local got, bb = false, nil
        if ok and BookInfo and BookInfo.getCoverImage then got, bb = pcall(BookInfo.getCoverImage, BookInfo, nil, file) end
        if got and bb then
            return ImageWidget:new{ image = bb, image_disposable = true, width = w, height = h, scale_factor = 0 }
        end
    end
    return View.cover(cached, w, h)
end

-- ♥♥♥♡♡ (rating 0..5)
function View.hearts(n)
    n = math.max(0, math.min(5, math.floor(tonumber(n) or 0)))
    return string.rep(Theme.heart, n) .. string.rep(Theme.open_heart, 5 - n)
end

View.SHELF_NAMES = {
    ["to-read"] = _("Want to Read"),
    ["currently-reading"] = _("Currently Reading"),
    ["read"] = _("Read"),
    ["did-not-finish"] = _("Did Not Finish"),
}

function View.shelfName(slug)
    return View.SHELF_NAMES[slug] or (slug or ""):gsub("%-", " ")
end

-- Pace for the yearly challenge, in Blossom's words.
function View.pace(read, goal, days_left, now)
    if not goal or goal < 1 then return _("no challenge yet ♡") end
    if read >= goal then return _("Goal reached! ♥") end
    local year = tonumber(os.date("%Y", now))
    local days = (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) and 366 or 365
    local left = math.max(0, math.min(days, tonumber(days_left) or (days - tonumber(os.date("%j", now)))))
    local diff = math.floor(read - goal * (days - left) / days + 0.5)
    if diff >= 1 then
        return diff == 1 and _("1 book ahead ♡") or T(_("%1 books ahead ♡"), diff)
    elseif diff <= -1 then
        return diff == -1 and _("1 book behind — you've got this ☆") or T(_("%1 books behind — you've got this ☆"), -diff)
    end
    return _("right on track ❀")
end

--------------------------------------------------------------------------------
-- Home
--------------------------------------------------------------------------------

local Home = Page:extend{}
View.Home = Home

function Home:bookCard()
    local p = self.plugin
    local file = p:currentFile()
    if not file then return nil end
    local entry = Store.open("books"):get(file) or {}
    local now = p:liveProgress() or {}
    local cover_w, cover_h = px(54), px(80)
    local inner = Theme.cardInner(self.inner_w) - cover_w - px(14)
    local lines = VerticalGroup:new{ align = "left" }
    local props = p.ui.doc_props or {}
    table.insert(lines, text(entry.title or props.title or _("This book"), Theme.face("script_bold", 18), { max_width = inner }))
    if entry.gid then
        table.insert(lines, muted(entry.author or "", 14, inner))
        table.insert(lines, vspan(4))
        local bits = { View.shelfName(entry.pushed_shelf or entry.pinned_shelf or "currently-reading") }
        if now.pct then bits[#bits + 1] = T(_("%1%"), now.pct) end
        if entry.rating then bits[#bits + 1] = View.hearts(entry.rating) end
        table.insert(lines, text(table.concat(bits, " · "), Theme.face("script", 15), { max_width = inner }))
    else
        table.insert(lines, vspan(4))
        table.insert(lines, muted(_("Not linked yet ♡ · Find on Goodreads"), 15, inner))
    end
    local row = HorizontalGroup:new{
        align = "center",
        View.bookCover(file, entry.gid, cover_w, cover_h),
        HorizontalSpan:new{ width = px(14) },
        lines,
    }
    return View.tap(Theme.card(row, { bordersize = 0, radius = px(14) }), function() p:showBook() end)
end

function Home:challengeCard()
    local p = self.plugin
    local ch = p:getSetting("challenge")
    local year = tonumber(os.date("%Y"))
    local inner = Theme.cardInner(self.inner_w) - px(24)
    local body = VerticalGroup:new{ align = "center", vspan(6),
        muted(T(_("my %1 Goodreads challenge"), year), 16) }
    if not ch or (ch.goal or 0) < 1 then
        table.insert(body, vspan(6))
        table.insert(body, View.tap(text(_("No challenge yet ♡ · Set a goal"), Theme.face("script_bold", 19)),
            function() self:editGoal(12) end))
    else
        table.insert(body, HorizontalGroup:new{
            align = "center",
            text(tostring(ch.read or 0), Theme.face("script_bold", 36)),
            text(T(_(" of %1 books"), ch.goal), Theme.face("script", 20)),
            View.tap(VerticalGroup:new{ align = "left", Theme.pencilIcon(18), vspan(18) },
                function() self:editGoal(ch.goal) end),
        })
        table.insert(body, vspan(6))
        table.insert(body, Theme.wave((ch.read or 0) / ch.goal, math.floor(inner * 0.9)))
        table.insert(body, vspan(8))
        table.insert(body, text(View.pace(ch.read or 0, ch.goal), Theme.face("script", 16), { max_width = inner }))
    end
    local counted = p:blossomCount()
    if counted then
        table.insert(body, vspan(2))
        table.insert(body, muted(T(_("Blossom counted %1 ❀"), counted), 14, inner))
    end
    table.insert(body, vspan(8))
    return Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = Theme.cardInner(self.inner_w), h = body:getSize().h },
        body,
    }, { bordersize = 0, radius = px(14) })
end

function Home:shelfTiles()
    local p = self.plugin
    local shelves = (p:getSetting("shelves") or {}).list or {}
    local group = VerticalGroup:new{ align = "center", Theme.rule(_("my shelves"), self.inner_w), vspan(10) }
    local cols = 2
    local tile_w = math.floor((self.inner_w - px(12)) / cols)
    local row
    for i, s in ipairs(shelves) do
        if i > 6 then break end
        if (i - 1) % cols == 0 then
            if row then table.insert(group, vspan(10)) end
            row = HorizontalGroup:new{ align = "center" }
            table.insert(group, row)
        elseif row then
            table.insert(row, HorizontalSpan:new{ width = px(12) })
        end
        local label = View.shelfName(s.slug) .. (s.count and ("  " .. s.count) or "")
        table.insert(row, View.tap(Theme.card(CenterContainer:new{
            dimen = Geom:new{ w = tile_w - 2 * px(6), h = px(34) },
            text(label, Theme.face("script", 16), { max_width = tile_w - px(16) }),
        }, { radius = px(10) }), function() self:openShelf(s.slug) end))
    end
    if #shelves == 0 then
        table.insert(group, View.tap(muted(_("Tap to gather your shelves ❀"), 16), function() self:loadShelves() end))
    end
    table.insert(group, vspan(14))
    table.insert(group, View.tap(Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = Theme.cardInner(self.inner_w), h = px(34) },
        text(_("⌕  Find a book…"), Theme.face("script", 16)),
    }, { bordersize = 0, radius = px(17) }), function() self:search() end))
    return group
end

function Home:content()
    local p = self.plugin
    local Login = require("blossomreads_login")
    local group = VerticalGroup:new{ align = "center" }
    if not Login.signedIn() then
        table.insert(group, vspan(30))
        table.insert(group, text(Theme.flower, Theme.face("ui", 44), { color = Theme.soft_ink }))
        table.insert(group, vspan(10))
        table.insert(group, View.tap(Theme.card(CenterContainer:new{
            dimen = Geom:new{ w = px(260), h = px(40) },
            text(_("Sign in to Goodreads ♡"), Theme.face("script_bold", 18)),
        }, { radius = px(20) }), function() self:onClose(); p:signIn() end))
        return group
    end
    local book = self:bookCard()
    if book then
        table.insert(group, book)
        table.insert(group, vspan(14))
    end
    table.insert(group, self:challengeCard())
    table.insert(group, vspan(16))
    table.insert(group, self:shelfTiles())
    return group
end

function Home:loadShelves()
    local list = self.plugin:busy(function(api) return api:shelves() end)
    if list then
        self.plugin:setSetting("shelves", { list = list, at = os.time() })
        self:refresh()
    end
end

function Home:loadChallenge()
    local ch = self.plugin:busy(function(api) return api:challenge() end)
    if ch then
        self.plugin:setSetting("challenge", { goal = ch.goal, read = ch.read, at = os.time() })
        self:refresh()
    end
end

-- Goodreads' goal; Blossom's too when they're linked.
function View.setGoal(plugin, n)
    local ok = plugin:busy(function(api) return api:setGoal(n) end)
    if not ok then return false end
    local ch = plugin:getSetting("challenge") or { read = 0 }
    ch.goal = n
    plugin:setSetting("challenge", ch)
    if plugin:goalLinked() then
        local Plan = require("blossomreads_plan")
        plugin.setBlossomGoal(Plan.clampGoal(n))
        plugin:setSetting("goal_synced", n)
    end
    return true
end

function Home:editGoal(goal)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Books to read this year ♡"),
        value = goal, value_min = 1, value_max = 999, value_step = 1, value_hold_step = 5,
        ok_text = _("Save ♥"),
        callback = function(spin)
            if View.setGoal(self.plugin, spin.value) then self:refresh() end
        end,
    })
end

function Home:openShelf(slug)
    require("blossomreads_list").shelf(self.plugin, slug)
end

function Home:search()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Find a book ♡"),
        input_hint = _("Title, author or ISBN"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q ~= "" then require("blossomreads_list").search(self.plugin, q) end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local STALE = 30 * 60

function View.show(plugin)
    local Login = require("blossomreads_login")
    local home = Home:new{ plugin = plugin, title = _("My Goodreads") }
    home:show()
    if not Login.signedIn() then return home end
    -- Fresh challenge numbers and shelves when they're old and we're online.
    local ch, sh = plugin:getSetting("challenge"), plugin:getSetting("shelves")
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr:isConnected() then
        if not (ch and ch.at and os.time() - ch.at < STALE) then home:loadChallenge() end
        if not (sh and sh.at and os.time() - sh.at < STALE) then home:loadShelves() end
    end
    return home
end

return View
