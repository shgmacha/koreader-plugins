--[[--
Blossom's full-screen dashboard: five swipeable pages
(overview, this week, my books, this month, my year) drawn in soft grays.
--]]

local BlossomDay = require("blossom_day")
local BlossomDetail = require("blossom_detail")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RectSpan = require("ui/widget/rectspan")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local _ = require("gettext")

local Data = require("blossom_data")
local Theme = require("blossom_theme")

local px = Theme.px
local floor = math.floor
local text, vspan, cardInner = Theme.text, Theme.vspan, Theme.cardInner

local PAGES = { "overview", "week", "books", "month", "year" }
local TITLES = {
    overview = _("My reading garden"),
    week = _("This week"),
    books = _("My books"),
    month = _("This month"),
    year = _("My year"),
}
local WEEK_TILES = 4
local BOOK_COLS, BOOK_ROWS = 3, 2 -- This month gallery
local SHELF_COLS, SHELF_ROWS = 4, 2 -- My books gallery
local COVER_RATIO = 1.45

-- Small widgets --------------------------------------------------------------

--- A rounded bar on a soft track, filled from the bottom.
local Bar = Widget:extend{
    width = 0,
    height = 0,
    ratio = 0,
    strong = false, -- darker fill for the best day / month
}

function Bar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Bar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local r = floor(self.width / 2)
    bb:paintRoundedRect(x, y, self.width, self.height, Theme.petal, r)
    if self.ratio > 0 then
        local fill = math.min(self.height, math.max(self.width, floor(self.height * self.ratio + 0.5)))
        bb:paintRoundedRect(x, y + self.height - fill, self.width, fill,
            self.strong and Theme.accent or Theme.bar, r)
    end
end

local GoalWave = Theme.GoalWave

local RoundedFrame = Theme.RoundedFrame

--- Makes any widget tappable.
local Tappable = InputContainer:extend{
    callback = nil,
}

function Tappable:init()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

local function hspan(n) return HorizontalSpan:new{ width = n } end

--- Height of a group we're still adding to (VerticalGroup caches its layout on getSize).
local function heightOf(group)
    local h = group:getSize().h
    group:resetLayout()
    return h
end

--- A column chart of `values` ({label, seconds}), ♥ above the best one.
local function barChart(values, best, width, bar_h, today_index, small)
    local top_size, label_size = small and 11 or 12, small and 13 or 14
    local max = 0
    for _, v in ipairs(values) do max = math.max(max, v.seconds) end
    local col_w = floor(width / #values)
    local chart = HorizontalGroup:new{ align = "bottom" }
    for i, v in ipairs(values) do
        local top = v.top or " "
        if i == best then top = Theme.heart end
        table.insert(chart, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = bar_h + px(56) },
            VerticalGroup:new{
                align = "center",
                text(top, Theme.face("ui", top_size), { color = Theme.soft_ink, max_width = col_w }),
                vspan(2),
                Bar:new{
                    width = math.max(px(6), floor(col_w * 0.36)),
                    height = bar_h,
                    ratio = max > 0 and v.seconds / max or 0,
                    strong = i == best,
                },
                vspan(2),
                text(v.label, Theme.face(i == today_index and "bold" or "ui", label_size)),
            },
        })
    end
    return Theme.card(chart, { background = Theme.bg })
end

-- View -----------------------------------------------------------------------

local BlossomView = InputContainer:extend{
    stats = nil,
    hour = 12,
    covers = nil,      -- blossom_covers instance
    loadWeek = nil,    -- function() -> period summary
    loadMonth = nil,   -- function(y, m) -> period summary
    loadYear = nil,    -- function(y) -> year summary
    loadBook = nil,    -- function(id) -> book detail
    loadDay = nil,     -- function(date) -> books + highlights + bookmarks of that day
    getGoal = nil,     -- function() -> books per year
    setGoal = nil,     -- function(n)
    page = 1,
    month_mode = "covers", -- or "calendar"
    covers_fullscreen = true,
}

function BlossomView:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.margin = px(Theme.MARGIN)
    self.inner_w = self.width - 2 * self.margin
    local now = os.date("*t")
    self.this_year, self.this_month = now.year, now.month
    self.year, self.month = now.year, now.month
    self.periods = {}
    self.cover_bbs = {}

    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
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

function BlossomView:build()
    if self[1] then self[1]:free() end
    local header = Theme.header(TITLES[PAGES[self.page]], self.width, function() self:onClose() end, self)
    local footer = self:buildFooter()
    self.content_h = self.height - header:getSize().h - footer:getSize().h - px(Theme.TOP_GAP) - px(16)
    local content = self["build_" .. PAGES[self.page]](self)
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
            BottomContainer:new{ dimen = full, footer },
        },
    }
end

function BlossomView:buildFooter()
    local dots = {}
    for i = 1, #PAGES do
        dots[i] = i == self.page and Theme.heart or Theme.open_heart
    end
    local function arrow(glyph, fn)
        return Button:new{
            text = glyph,
            bordersize = 0,
            width = px(56),
            text_font_size = 24,
            callback = fn,
            show_parent = self,
        }
    end
    return VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            align = "center",
            arrow("‹", function() self:onPrevPage() end),
            hspan(px(8)),
            text(table.concat(dots, " "), Theme.face("ui", 13), { color = Theme.accent }),
            hspan(px(8)),
            arrow("›", function() self:onNextPage() end),
        },
        vspan(6),
    }
end

function BlossomView:emptyState(message)
    return VerticalGroup:new{
        align = "center",
        vspan(80),
        text(Theme.blossom, Theme.face("ui", 64), { color = Theme.accent }),
        vspan(10),
        TextBoxWidget:new{
            text = message,
            face = Theme.face("script", 22),
            width = self.inner_w,
            alignment = "center",
            bgcolor = Theme.bg,
        },
    }
end

-- Covers ---------------------------------------------------------------------

--- Cover blitbuffers are cached for the view's lifetime and freed on close.
function BlossomView:coverBB(md5)
    if not md5 or not self.covers then return end
    if self.cover_bbs[md5] == nil then
        self.cover_bbs[md5] = self.covers:coverFor(md5) or false
    end
    return self.cover_bbs[md5] or nil
end

--- The cover scaled to cover w×h completely, trimmed evenly at the sides (a fresh bb).
local function fillCrop(bb, w, h)
    local bw, bh = bb:getWidth(), bb:getHeight()
    local f = math.max(w / bw, h / bh)
    local sw, sh = math.max(w, math.ceil(bw * f)), math.max(h, math.ceil(bh * f))
    local scaled = RenderImage:scaleBlitBuffer(bb, sw, sh, false)
    local out = Blitbuffer.new(w, h, scaled:getType())
    out:blitFrom(scaled, 0, 0, floor((sw - w) / 2), floor((sh - h) / 2), w, h)
    if scaled ~= bb then scaled:free() end
    return out
end

--- The cover, or a soft placeholder with a flower (and the title if there's room).
--- With `fill`, the cover fills the whole box (cropped a little) instead of fitting inside it.
function BlossomView:art(book, w, h, show_title, fill)
    local dimen = Geom:new{ w = w, h = h }
    local bb = self:coverBB(book.md5)
    if bb and fill then
        return ImageWidget:new{ image = fillCrop(bb, w, h), image_disposable = true, width = w, height = h }
    end
    if bb then
        return CenterContainer:new{
            dimen = dimen,
            ImageWidget:new{ image = bb, image_disposable = false, width = w, height = h, scale_factor = 0 },
        }
    end
    local label = show_title
        and TextBoxWidget:new{
            text = Theme.flower .. "\n" .. book.title,
            face = Theme.face("script", 14),
            width = w - px(8),
            height = h - px(8),
            height_overflow_show_ellipsis = true,
            alignment = "center",
            bgcolor = Theme.petal,
        }
        or text(Theme.flower, Theme.face("ui", math.max(12, floor(h / 3))), { color = Theme.bg })
    return FrameContainer:new{
        width = w,
        height = h,
        background = Theme.petal,
        bordersize = 0,
        padding = 0,
        radius = px(6),
        CenterContainer:new{ dimen = dimen, label },
    }
end

function BlossomView:tappable(widget, book)
    return Tappable:new{
        callback = function() self:openBook(book.id) end,
        widget,
    }
end

--- A polaroid-style tile: cover (or a cute placeholder) and caption lines.
function BlossomView:tile(book, cover_w, cover_h, captions)
    captions = captions or { self:timeCaption(book, Theme.face("script", 14), cover_w) }
    local body = VerticalGroup:new{ align = "center", self:art(book, cover_w, cover_h, true) }
    for _, line in ipairs(captions) do table.insert(body, line) end
    return self:tappable(FrameContainer:new{
        bordersize = Size.border.thin,
        color = Theme.accent,
        radius = px(8),
        background = Theme.bg,
        padding = px(4),
        margin = 0,
        body,
    }, book)
end

--- "5h 27m", with a bow in front when the book is finished.
function BlossomView:timeCaption(book, face, max_w, prefix)
    local label = text((prefix or "") .. Data.fmtDuration(book.seconds), face, { max_width = max_w })
    if book.finished then return Theme.withBow(label, 18, "left") end
    return label
end

local TILE_PAD = 4
local function tileChrome() return 2 * (px(TILE_PAD) + Size.border.thin) end

--- Sizes covers to fit `cols` per row within `avail_h` per row (with `lines` caption lines).
function BlossomView:coverSize(cols, gap, avail_h, lines)
    local tile_w = floor((self.inner_w - (cols - 1) * gap) / cols)
    local cover_w = tile_w - tileChrome()
    local caption_h = text("0m", Theme.face("script", 14)):getSize().h * (lines or 1)
    local cover_h = math.min(floor(cover_w * COVER_RATIO), avail_h - caption_h - tileChrome())
    return cover_w, cover_h
end

function BlossomView:tileRow(books, from, to, cover_w, cover_h, gap)
    local row = HorizontalGroup:new{ align = "top" }
    for i = from, to do
        if i > from then table.insert(row, hspan(gap)) end
        table.insert(row, self:tile(books[i], cover_w, cover_h))
    end
    return row
end

--- Loads data once, with a gentle message while petals (covers) are gathered.
function BlossomView:period(key, loader)
    if self.periods[key] == nil then
        local msg = InfoMessage:new{ text = _("Gathering petals… ❀") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        self.periods[key] = loader() or Data.summarizePeriod({}, 0)
        UIManager:close(msg)
    end
    return self.periods[key]
end

function BlossomView:openBook(id)
    local detail = id and self.loadBook and self.loadBook(id)
    if not detail then
        UIManager:show(InfoMessage:new{ text = _("Couldn't find this book's petals ❀"), timeout = 3 })
        return
    end
    UIManager:show(BlossomDetail:new{
        book = detail,
        art = function(book, w, h, fill) return self:art(book, w, h, true, fill) end,
        aspect = function(book)
            local bb = self:coverBB(book.md5)
            return bb and bb:getHeight() / bb:getWidth() or nil
        end,
    }, "flashui")
end

function BlossomView:openDay(date)
    local day = self.loadDay and self:period("day:" .. date, function() return self.loadDay(date) end)
    if not day then return end
    UIManager:show(BlossomDay:new{
        day = day,
        art = function(book, w, h) return self:art(book, w, h, false) end,
        tappable = function(widget, book) return self:tappable(widget, book) end,
    }, "flashui")
end

-- Pages ------------------------------------------------------------------------

function BlossomView:build_overview()
    local s = self.stats
    if s.empty then
        return self:emptyState(s.db_error
            and _("Couldn't open your reading statistics. Is the Statistics plugin enabled? ♡")
            or _("Your garden is waiting to bloom ❀\nStart reading and your stats will grow here."))
    end
    -- No frames: a greeting, soft numbers on the page, a quiet line of love. Centred.
    local streak_label = s.streak == 1 and _("day streak") or _("days streak")
    local stats = Theme.statGrid({
        { Theme.flower, tostring(s.books), _("books loved") },
        { Theme.open_heart, Data.fmtDuration(s.seconds), _("of stories") },
        { Theme.blossom, tostring(s.pages), _("pages turned") },
        { Theme.heart, tostring(s.streak), streak_label },
        { Theme.star, Data.fmtDuration(s.today_seconds), _("read today") },
        { "✧", Data.fmtDuration(s.week_seconds), _("this week") },
    }, math.min(self.inner_w, px(600)), 3, { value_size = 21, label_size = 15, cell_h = 66, row_gap = 34 })
    local garden = VerticalGroup:new{
        align = "center",
        text(Data.greeting(self.hour), Theme.face("script", 24)),
        vspan(6),
        text(Data.affirmation(s.today), Theme.face("script", 16), { color = Theme.soft_ink }),
        vspan(40),
        stats,
        vspan(30),
        text(string.format(_("longest streak: %d days %s"), s.longest_streak, Theme.star),
            Theme.face("script", 15), { color = Theme.soft_ink }),
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.content_h },
        garden,
    }
end

function BlossomView:build_week()
    local s = self.stats
    local gap = px(10)
    local best = s.best_day_index and s.week[s.best_day_index]
    local headline = VerticalGroup:new{
        align = "center",
        text(string.format(_("%s of reading %s"), Data.fmtDuration(s.week_seconds), Theme.open_heart),
            Theme.face("script_bold", 18)),
        text(best and string.format(_("best day: %s %s"), os.date("%A", os.time{
                year = tonumber(best.date:sub(1, 4)), month = tonumber(best.date:sub(6, 7)),
                day = tonumber(best.date:sub(9, 10)), hour = 12 }), Theme.heart)
            or _("a fresh week to bloom ❀"),
            Theme.face("script", 14), { color = Theme.soft_ink }),
    }
    local days = {}
    for i, day in ipairs(s.week) do
        days[i] = { label = day.label, seconds = day.seconds,
                    top = day.seconds > 0 and Data.fmtDuration(day.seconds) or nil }
    end
    -- The bars without a frame, then how the week went.
    local chart = barChart(days, s.best_day_index, floor(self.inner_w * 0.82),
        math.max(px(40), floor(self.content_h * 0.2)), #days, true)[1]

    local group = VerticalGroup:new{
        align = "center",
        vspan(6),
        chart,
        vspan(10),
        headline,
        vspan(48),
    }

    local week = self:period("week", self.loadWeek)
    table.insert(group, text(_("Books that kept me company ♡"), Theme.face("script_bold", 16)))
    table.insert(group, vspan(12))
    if week.books == 0 then
        table.insert(group, text(_("No books yet this week ❀"), Theme.face("script", 16), { color = Theme.soft_ink }))
        return group
    end
    local shown = math.min(WEEK_TILES, week.books)
    local avail = self.content_h - heightOf(group) - px(24)
    local cover_w, cover_h = self:coverSize(WEEK_TILES, gap, avail)
    if cover_h < px(50) then
        -- Too little room for covers: a sweet list instead.
        for i = 1, shown do
            local b = week.list[i]
            table.insert(group, self:tappable(text(string.format("%s %s · %s", Theme.flower, b.title,
                Data.fmtDuration(b.seconds)), Theme.face("script", 16), { max_width = self.inner_w }), b))
        end
    else
        -- Just the covers, each in a soft rounded frame, shaped like a book.
        cover_h = math.min(cover_h, px(150))
        cover_w = math.min(cover_w, floor(cover_h / COVER_RATIO))
        cover_h = floor(cover_w * COVER_RATIO)
        local row = HorizontalGroup:new{ align = "top" }
        for i = 1, shown do
            if i > 1 then table.insert(row, hspan(gap)) end
            table.insert(row, self:tappable(Theme.RoundedFrame:new{
                radius = px(8),
                bordersize = Size.border.thin,
                color = Theme.petal,
                background = Theme.bg,
                outside = Theme.bg,
                self:art(week.list[i], cover_w, cover_h, true, true),
            }, week.list[i]))
        end
        table.insert(group, row)
    end
    if week.books > shown then
        table.insert(group, text(string.format(_("+%d more %s"), week.books - shown, Theme.open_heart),
            Theme.face("script", 14), { color = Theme.soft_ink }))
    end
    return group
end


--- Gallery tile: one rounded frame holding the cover edge to edge, then title and progress.
function BlossomView:galleryTile(b, w, cover_h)
    local border = Size.border.thin
    local inner = w - 2 * border
    local pad = px(6)
    local prefix = not b.finished and string.format("%d%% · ", floor(b.progress * 100 + 0.5)) or nil
    return self:tappable(RoundedFrame:new{
        radius = px(10),
        bordersize = border,
        color = Theme.accent,
        background = Theme.bg,
        outside = Theme.bg,
        VerticalGroup:new{
            align = "center",
            self:art(b, inner, cover_h, true, true),
            vspan(6),
            text(b.title, Theme.face("bold", 14), { max_width = inner - 2 * pad }),
            self:timeCaption(b, Theme.face("script", 15), inner - 2 * pad, prefix),
            vspan(7),
        },
    }, b)
end

--- A gallery of recent covers with % read and time spent.
function BlossomView:build_books()
    local s = self.stats
    if #s.recent == 0 then
        return self:emptyState(_("No books on your shelf yet ❀\nOpen a book and it will bloom here."))
    end
    -- A touch smaller than the full page, centred, so the gallery can breathe.
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.content_h },
        self:galleryGrid(s.recent, floor(self.content_h * 0.86), SHELF_COLS, SHELF_ROWS),
    }
end

--- Up to 3×2 framed covers fitting `avail_h`; narrower tiles when height is tight,
--- so covers keep their book shape.
function BlossomView:galleryGrid(books, avail_h, cols, rows)
    cols, rows = cols or BOOK_COLS, rows or BOOK_ROWS
    local gap_x, gap_y = px(cols > 3 and 12 or 16), px(18)
    local caption_h = text("Ag", Theme.face("bold", 14)):getSize().h + text("Ag", Theme.face("script", 15)):getSize().h + px(13)
    local border = 2 * Size.border.thin
    local row_h = floor((avail_h - gap_y * (rows - 1)) / rows)
    local cover_h = row_h - caption_h - border
    local tile_w = math.min(floor((self.inner_w - gap_x * (cols - 1)) / cols),
                            floor(cover_h / COVER_RATIO) + border)
    cover_h = math.min(cover_h, floor((tile_w - border) * COVER_RATIO))
    local group = VerticalGroup:new{ align = "center" }
    local shown = math.min(#books, cols * rows)
    for r = 1, math.ceil(shown / cols) do
        local row = HorizontalGroup:new{ align = "top" }
        for i = (r - 1) * cols + 1, math.min(shown, r * cols) do
            if #row > 0 then table.insert(row, hspan(gap_x)) end
            table.insert(row, self:galleryTile(books[i], tile_w, cover_h))
        end
        if r > 1 then table.insert(group, VerticalSpan:new{ width = gap_y }) end
        table.insert(group, row)
    end
    return group
end

--- A calendar day: shaded by reading, with the date in the corner; book bars run across it.
function BlossomView:readDay(day, cell, border)
    local inner = cell - 2 * border
    local pad = px(5)
    local number = text(tostring(day.day), Theme.face(day.today and "bold" or "ui", 11),
        { color = day.today and Theme.ink or Theme.soft_ink })
    return FrameContainer:new{
        width = cell,
        height = cell,
        padding = 0,
        margin = 0,
        radius = px(8),
        bordersize = border,
        color = day.today and Theme.ink or Theme.petal,
        background = Theme.shades[day.level + 1],
        -- A fixed-size body: the date top-left, the rest left for book bars.
        OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = inner },
            HorizontalGroup:new{ hspan(pad), number },
        },
    }
end

--- A rounded bar with the book's title, spanning the days of a week it was read.
function BlossomView:bookBar(title, w, h)
    return FrameContainer:new{
        padding = 0,
        margin = 0,
        radius = floor(h / 2),
        bordersize = Size.border.thin,
        color = Theme.ink,
        background = Theme.bg,
        LeftContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.border.thin, h = h - 2 * Size.border.thin },
            HorizontalGroup:new{
                align = "center",
                hspan(px(6)),
                text(title, Theme.face("script", 12), { max_width = w - px(14) }),
            },
        },
    }
end

--- One calendar week: its cells with book bars laid over the bottom of them.
function BlossomView:calendarWeek(cells, week_start, spans, cell, gap)
    local row = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(cells) do
        if i > 1 then table.insert(row, hspan(gap)) end
        table.insert(row, w)
    end
    local width = 7 * cell + 6 * gap
    local week = OverlapGroup:new{ dimen = Geom:new{ w = width, h = cell }, row }
    local bar_h = math.max(px(14), floor(cell * 0.2))
    local inset = px(3)
    for _, part in ipairs(Data.weekLanes(spans, week_start, 2)) do
        local x = (part.col_from - 1) * (cell + gap) + inset
        local w = (part.col_to - part.col_from + 1) * (cell + gap) - gap - 2 * inset
        local bar = self:bookBar(part.title .. " · " .. Data.fmtDuration(part.seconds), w, bar_h)
        bar.overlap_offset = { x, cell - inset - part.lane * (bar_h + px(2)) }
        table.insert(week, bar)
    end
    return week
end

--- Days with reading open the day page.
function BlossomView:dayTappable(widget, day)
    if day.seconds <= 0 then return widget end
    return Tappable:new{
        callback = function() self:openDay(day.date) end,
        widget,
    }
end

function BlossomView:calendarGrid(avail_h, top_by_date, spans)
    local cal = Data.calendar(self.year, self.month, self.stats.by_date, self.stats.today, top_by_date)
    local gap = px(4)
    local header_h = text("Su", Theme.face("bold", 14)):getSize().h
    local legend_h = px(30)
    local cell = floor(math.min((self.inner_w - 6 * gap) / 7,
        (avail_h - header_h - legend_h - cal.rows * gap) / cal.rows))
    local function row(items)
        local r = HorizontalGroup:new{ align = "center" }
        for i, w in ipairs(items) do
            if i > 1 then table.insert(r, hspan(gap)) end
            table.insert(r, w)
        end
        return r
    end
    local grid = VerticalGroup:new{ align = "center" }
    local heads = {}
    for i, h in ipairs(cal.headers) do
        heads[i] = CenterContainer:new{
            dimen = Geom:new{ w = cell, h = header_h },
            text(h, Theme.face("bold", 14), { color = Theme.soft_ink }),
        }
    end
    table.insert(grid, row(heads))
    for r = 1, cal.rows do
        local cells = {}
        for c = 1, 7 do
            local day = cal.cells[(r - 1) * 7 + c]
            if not day then
                cells[c] = RectSpan:new{ width = cell, height = cell }
            else
                -- Every day: shaded by reading, date in the corner (dayTappable skips days without reading).
                cells[c] = self:dayTappable(self:readDay(day, cell, day.today and Size.border.thick or Size.border.thin), day)
            end
        end
        table.insert(grid, VerticalSpan:new{ width = gap })
        table.insert(grid, self:calendarWeek(cells, Data.addDays(cal.start, (r - 1) * 7), spans, cell, gap))
    end
    -- Legend: less ▢ ▢ ▢ ▢ more
    local legend = HorizontalGroup:new{ align = "center",
        text(_("less "), Theme.face("script", 14), { color = Theme.soft_ink }) }
    for i = 1, #Theme.shades do
        table.insert(legend, FrameContainer:new{
            padding = 0, margin = 0, radius = px(4),
            bordersize = Size.border.thin, color = Theme.accent, background = Theme.shades[i],
            RectSpan:new{ width = px(16), height = px(16) },
        })
        table.insert(legend, hspan(px(4)))
    end
    table.insert(legend, text(_(" more"), Theme.face("script", 14), { color = Theme.soft_ink }))
    table.insert(grid, vspan(8))
    table.insert(grid, legend)
    return grid
end

function BlossomView:build_month()
    local gap = px(10)
    local key = string.format("%04d-%02d", self.year, self.month)
    local month = self:period(key, function() return self.loadMonth(self.year, self.month) end)
    local is_current = self.year == self.this_year and self.month == self.this_month
    local calendar_mode = self.month_mode == "calendar"

    local function nav(glyph, enabled, delta)
        return Button:new{
            text = glyph,
            bordersize = 0,
            width = px(40),
            text_font_size = 26,
            enabled = enabled,
            callback = function() self:shiftMonth(delta) end,
            show_parent = self,
        }
    end
    -- "▦  ‹ September 2026 ›  ❀": plain icons; the view you're on is black, the other soft gray.
    local function mode(label, key)
        local active = self.month_mode == key
        local icon = text(label, Theme.face("ui", 22), { color = active and Theme.ink or Theme.bar })
        icon.mode_key, icon.active = key, active
        return Tappable:new{
            callback = function()
                if self.month_mode ~= key then
                    self.month_mode = key
                    self:refresh()
                end
            end,
            CenterContainer:new{ dimen = Geom:new{ w = px(48), h = px(44) }, icon },
        }
    end
    local left, right = mode("▦", "calendar"), mode("❀", "covers")
    local side_w = math.max(left:getSize().w, right:getSize().w)
    local title_w = self.inner_w - 2 * side_w - 2 * px(40)
    local switcher = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = side_w, h = px(44) }, left },
        nav("‹", true, -1),
        CenterContainer:new{
            dimen = Geom:new{ w = title_w, h = px(44) },
            text(Data.monthTitle(self.year, self.month), Theme.face("script_bold", 20), { max_width = title_w }),
        },
        nav("›", not is_current, 1),
        CenterContainer:new{ dimen = Geom:new{ w = side_w, h = px(44) }, right },
    }
    local summary = string.format(_("%s · %d pages · %d days · %d books"),
        Data.fmtDuration(month.seconds), month.pages, month.days_read, month.books)
    local pill = Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = cardInner(self.inner_w), h = px(30) },
        text(summary, Theme.face("script", 15), { max_width = cardInner(self.inner_w) }),
    }, { radius = px(18) })

    local group = VerticalGroup:new{
        align = "center",
        switcher,
        vspan(4),
        pill,
        VerticalSpan:new{ width = gap },
    }
    if calendar_mode then
        table.insert(group, self:calendarGrid(self.content_h - heightOf(group), month.top_by_date, month.spans))
        return group
    end
    if month.books == 0 then
        table.insert(group, vspan(30))
        table.insert(group, text(_("No blooms this month ❀"), Theme.face("script", 22), { color = Theme.soft_ink }))
        return group
    end

    local shown = math.min(BOOK_COLS * BOOK_ROWS, month.books)
    local more_h = month.books > shown and px(28) or 0
    table.insert(group, self:galleryGrid(month.list, floor((self.content_h - heightOf(group) - more_h) * 0.94)))
    if month.books > shown then
        table.insert(group, vspan(6))
        table.insert(group, text(string.format(_("+%d more %s"), month.books - shown, Theme.open_heart),
            Theme.face("script", 16), { color = Theme.soft_ink }))
    end
    return group
end

--- The wavy goal line with a heart riding it where you are.
function BlossomView:goalWave(ratio, width)
    return Theme.wave(ratio, width)
end

function BlossomView:build_year()
    local gap = px(20)
    local year = self:period("year:" .. self.this_year, function() return self.loadYear(self.this_year) end)
    local goal = Data.validGoal(self.getGoal and self.getGoal())
    local status = Data.goalStatus(year.finished, goal, self.stats.today)
    local card_inner = cardInner(self.inner_w) - 2 * px(12)
    local fresh = year.seconds == 0 and year.finished == 0

    -- The goal, in one soft borderless card with room to breathe.
    local wave_w = floor(card_inner * 0.9)
    local pct = floor(math.min(1, year.finished / goal) * 100 + 0.5)
    local ends = OverlapGroup:new{
        dimen = Geom:new{ w = wave_w, h = text("0", Theme.face("script", 14)):getSize().h },
        text(_("start"), Theme.face("script", 14), { color = Theme.soft_ink }),
    }
    local goal_label = text(string.format(_("%d books ♡"), goal), Theme.face("script", 14), { color = Theme.soft_ink })
    goal_label.overlap_align = "right"
    table.insert(ends, goal_label)
    local hero = VerticalGroup:new{
        align = "center",
        vspan(6),
        text(string.format(_("my %d reading goal"), self.this_year), Theme.face("script", 16), { color = Theme.soft_ink }),
        vspan(2),
        HorizontalGroup:new{
            align = "center",
            text(tostring(year.finished), Theme.face("script_bold", 40)),
            text(string.format(_(" of %d books"), goal), Theme.face("script", 22)),
            -- A little superscript pencil, tip towards the "s": tap to change the goal.
            Tappable:new{
                callback = function() self:editGoal(goal) end,
                VerticalGroup:new{
                    align = "left",
                    Theme.pencilIcon(20),
                    vspan(22),
                },
            },
        },
        vspan(8),
        self:goalWave(year.finished / goal, wave_w),
        ends,
        vspan(10),
        text(string.format(_("%d%% of my goal · %s"), pct, fresh and _("a fresh year to bloom ❀") or status.message),
            Theme.face("script", 17), { max_width = card_inner }),
        vspan(10),
    }

    local group = VerticalGroup:new{
        align = "center",
        Theme.card(CenterContainer:new{
            dimen = Geom:new{ w = cardInner(self.inner_w), h = hero:getSize().h + px(8) },
            hero,
        }, { bordersize = 0, radius = px(10) }),
        VerticalSpan:new{ width = gap },
        Theme.statStrip({
            { Data.fmtDuration(year.seconds), _("read") },
            { tostring(year.pages), _("pages") },
            { tostring(year.days_read), year.days_read == 1 and _("day") or _("days") },
        }, self.inner_w, px(10)),
        VerticalSpan:new{ width = gap },
        Theme.rule(_("reading by month"), self.inner_w),
        vspan(6),
    }
    hero:resetLayout()

    local bar_h = math.max(px(40), math.min(px(170), self.content_h - heightOf(group) - px(64)))
    table.insert(group, self:monthChart(year, bar_h))
    return group
end

--- Open (unboxed) month chart: slim bars, ♥ over the best month, this month in bold.
function BlossomView:monthChart(year, bar_h)
    local chart = barChart(year.months, year.best_month, self.inner_w, bar_h, self.this_month)
    return chart[1] -- the bars without the card frame
end

function BlossomView:editGoal(goal)
    UIManager:show(SpinWidget:new{
        title_text = _("Books to read this year ♡"),
        value = goal,
        value_min = 1,
        value_max = 365,
        value_step = 1,
        value_hold_step = 5,
        ok_text = _("Save ♥"),
        callback = function(spin)
            if self.setGoal then self.setGoal(spin.value) end
            self:refresh()
        end,
    })
end

-- Navigation -------------------------------------------------------------------

function BlossomView:refresh()
    self:build()
    UIManager:setDirty(self, "flashui")
end

function BlossomView:goToPage(page)
    self.page = (page - 1) % #PAGES + 1
    self:refresh()
end

function BlossomView:shiftMonth(delta)
    local y, m = Data.shiftMonth(self.year, self.month, delta)
    if y * 12 + m > self.this_year * 12 + self.this_month then return end
    self.year, self.month = y, m
    self:refresh()
end

function BlossomView:onNextPage()
    self:goToPage(self.page + 1)
    return true
end

function BlossomView:onPrevPage()
    self:goToPage(self.page - 1)
    return true
end

function BlossomView:onSwipe(_, ges)
    local dir = ges.direction
    if dir == "west" then return self:onNextPage() end
    if dir == "east" then return self:onPrevPage() end
    if dir == "south" then return self:onClose() end
    return true
end

function BlossomView:onClose()
    UIManager:close(self)
    return true
end

function BlossomView:onCloseWidget()
    if self[1] then self[1]:free() end
    for md5, bb in pairs(self.cover_bbs) do
        if bb and bb.free then bb:free() end
        self.cover_bbs[md5] = nil
    end
    UIManager:setDirty(nil, "full")
end

-- Exposed for tests.
BlossomView.PAGES = PAGES
BlossomView.Bar = Bar
BlossomView.Tappable = Tappable
BlossomView.GoalWave = GoalWave
BlossomView.RoundedFrame = RoundedFrame

return BlossomView
