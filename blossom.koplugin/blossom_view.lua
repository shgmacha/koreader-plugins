--[[--
Blossom's full-screen dashboard: four swipeable pages
(overview, this week, my books, this month) drawn in soft grays.
--]]

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
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
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

local PAGES = { "overview", "week", "books", "month" }
local TITLES = {
    overview = _("My reading garden"),
    week = _("This week"),
    books = _("My books"),
    month = _("This month"),
}
local WEEK_TILES = 4
local MONTH_COLS, MONTH_ROWS = 3, 3
local COVER_RATIO = 1.45

-- Small widgets --------------------------------------------------------------

--- A rounded bar on a soft track, filled from the bottom.
local Bar = Widget:extend{
    width = 0,
    height = 0,
    ratio = 0,
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
        bb:paintRoundedRect(x, y + self.height - fill, self.width, fill, Theme.accent, r)
    end
end

local function text(str, face, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = face,
        fgcolor = opts.color or Theme.ink,
        max_width = opts.max_width,
        bold = opts.bold,
    }
end

local function vspan(n) return VerticalSpan:new{ width = px(n) } end
local function hspan(n) return HorizontalSpan:new{ width = n } end

--- Width left for content inside Theme.card with default padding.
local function cardInner(w)
    return w - 2 * (Size.padding.default + Size.border.thin)
end

-- View -----------------------------------------------------------------------

local BlossomView = InputContainer:extend{
    stats = nil,
    hour = 12,
    covers = nil,      -- blossom_covers instance
    loadWeek = nil,    -- function() -> period summary
    loadMonth = nil,   -- function(y, m) -> period summary
    page = 1,
    covers_fullscreen = true,
}

function BlossomView:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.margin = px(16)
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
    local header = self:buildHeader()
    local footer = self:buildFooter()
    self.content_h = self.height - header:getSize().h - footer:getSize().h - px(8)
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
                CenterContainer:new{
                    dimen = Geom:new{ w = self.width, h = self.content_h },
                    content,
                },
            },
            BottomContainer:new{ dimen = full, footer },
        },
    }
end

function BlossomView:buildHeader()
    local titles = VerticalGroup:new{
        align = "center",
        vspan(8),
        text("˚ ✿ Blossom ✿ ˚", Theme.face("ui", 14), { color = Theme.soft_ink }),
        text(TITLES[PAGES[self.page]], Theme.face("script_bold", 28)),
        text(Theme.ribbon, Theme.face("ui", 14), { color = Theme.accent }),
        vspan(4),
    }
    local close = Button:new{
        text = "✕",
        bordersize = 0,
        text_font_size = 22,
        callback = function() self:onClose() end,
        show_parent = self,
    }
    close.overlap_align = "right"
    titles.overlap_align = "center"
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = titles:getSize().h },
        titles,
        close,
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
            width = px(70),
            text_font_size = 30,
            callback = fn,
            show_parent = self,
        }
    end
    return VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            align = "center",
            arrow("‹", function() self:onPrevPage() end),
            hspan(px(16)),
            text(table.concat(dots, "   "), Theme.face("ui", 20), { color = Theme.accent }),
            hspan(px(16)),
            arrow("›", function() self:onNextPage() end),
        },
        vspan(6),
    }
end

function BlossomView:emptyState(message)
    return VerticalGroup:new{
        align = "center",
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

--- A polaroid-style tile: cover (or a cute placeholder) and a caption.
function BlossomView:tile(book, cover_w, cover_h)
    local dimen = Geom:new{ w = cover_w, h = cover_h }
    local bb = self:coverBB(book.md5)
    local art
    if bb then
        art = CenterContainer:new{
            dimen = dimen,
            ImageWidget:new{
                image = bb,
                image_disposable = false,
                width = cover_w,
                height = cover_h,
                scale_factor = 0,
            },
        }
    else
        art = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            background = Theme.petal,
            bordersize = 0,
            padding = 0,
            radius = px(6),
            CenterContainer:new{
                dimen = dimen,
                TextBoxWidget:new{
                    text = Theme.flower .. "\n" .. book.title,
                    face = Theme.face("script", 14),
                    width = cover_w - px(8),
                    height = cover_h - px(8),
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                    bgcolor = Theme.petal,
                },
            },
        }
    end
    local caption = Data.fmtDuration(book.seconds) .. (book.finished and (" " .. Theme.heart) or "")
    return FrameContainer:new{
        bordersize = Size.border.thin,
        color = Theme.accent,
        radius = px(8),
        background = Theme.bg,
        padding = px(4),
        margin = 0,
        VerticalGroup:new{
            align = "center",
            art,
            text(caption, Theme.face("script", 14), { max_width = cover_w }),
        },
    }
end

local TILE_PAD = 4
local function tileChrome() return 2 * (px(TILE_PAD) + Size.border.thin) end

--- Sizes covers to fit `cols` per row within `avail_h` per row.
function BlossomView:coverSize(cols, gap, avail_h)
    local tile_w = floor((self.inner_w - (cols - 1) * gap) / cols)
    local cover_w = tile_w - tileChrome()
    local caption_h = text("0m", Theme.face("script", 14)):getSize().h
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

--- Loads a period once, with a gentle message while covers are gathered.
function BlossomView:period(key, loader)
    if self.periods[key] == nil then
        local msg = InfoMessage:new{ text = _("Gathering petals… ✿") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        self.periods[key] = loader() or Data.summarizePeriod({}, 0)
        UIManager:close(msg)
    end
    return self.periods[key]
end

-- Pages ------------------------------------------------------------------------

function BlossomView:build_overview()
    local s = self.stats
    if s.empty then
        return self:emptyState(s.db_error
            and _("Couldn't open your reading statistics. Is the Statistics plugin enabled? ♡")
            or _("Your garden is waiting to bloom ✿\nStart reading and your stats will grow here."))
    end
    local gap = px(10)
    local card_w = floor((self.inner_w - gap) / 2)
    local inner = cardInner(card_w)
    local greeting = text(Data.greeting(self.hour), Theme.face("script", 22))
    local pill = Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = cardInner(self.inner_w), h = px(34) },
        text(Data.affirmation(s.today), Theme.face("script", 18), { max_width = cardInner(self.inner_w) }),
    }, { radius = px(20) })
    local longest = text(string.format(_("longest streak: %d days %s"), s.longest_streak, Theme.star),
        Theme.face("script", 16), { color = Theme.soft_ink })

    local fixed = greeting:getSize().h + pill:getSize().h + longest:getSize().h + gap * 5
    local card_h = math.min(px(84), floor((self.content_h - fixed) / 3) - 2 * (Size.padding.default + Size.border.thin))

    local function stat(glyph, value, label)
        return Theme.card(CenterContainer:new{
            dimen = Geom:new{ w = inner, h = card_h },
            VerticalGroup:new{
                align = "center",
                text(glyph .. " " .. value, Theme.face("bold", 22), { max_width = inner }),
                text(label, Theme.face("script", 16), { color = Theme.soft_ink, max_width = inner }),
            },
        })
    end
    local function row(a, b)
        return HorizontalGroup:new{ a, hspan(gap), b }
    end
    local streak_label = s.streak == 1 and _("day streak") or _("days streak")
    return VerticalGroup:new{
        align = "center",
        greeting,
        vspan(6),
        row(stat(Theme.flower, tostring(s.books), _("books loved")),
            stat(Theme.open_heart, Data.fmtDuration(s.seconds), _("of stories"))),
        VerticalSpan:new{ width = gap },
        row(stat(Theme.blossom, tostring(s.pages), _("pages turned")),
            stat(Theme.heart, tostring(s.streak), streak_label)),
        VerticalSpan:new{ width = gap },
        row(stat(Theme.star, Data.fmtDuration(s.today_seconds), _("read today")),
            stat(Theme.flower, Data.fmtDuration(s.week_seconds), _("this week"))),
        VerticalSpan:new{ width = gap },
        longest,
        VerticalSpan:new{ width = gap },
        pill,
    }
end

function BlossomView:weekChart()
    local s = self.stats
    local max = 0
    for _, day in ipairs(s.week) do max = math.max(max, day.seconds) end
    local col_w = floor(cardInner(self.inner_w) / 7)
    local bar_h = math.max(px(40), floor(self.content_h * 0.28))
    local chart = HorizontalGroup:new{ align = "bottom" }
    for i, day in ipairs(s.week) do
        local top = day.seconds > 0 and Data.fmtDuration(day.seconds) or " "
        if i == s.best_day_index then top = Theme.heart end
        local is_today = i == #s.week
        table.insert(chart, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = bar_h + px(56) },
            VerticalGroup:new{
                align = "center",
                text(top, Theme.face("ui", 12), { color = Theme.soft_ink, max_width = col_w }),
                vspan(2),
                Bar:new{
                    width = floor(col_w * 0.5),
                    height = bar_h,
                    ratio = max > 0 and day.seconds / max or 0,
                },
                vspan(2),
                text(day.label, Theme.face(is_today and "bold" or "ui", 14)),
            },
        })
    end
    return Theme.card(chart, { background = Theme.bg })
end

function BlossomView:build_week()
    local s = self.stats
    local gap = px(10)
    local best = s.best_day_index and s.week[s.best_day_index]
    local headline = VerticalGroup:new{
        align = "center",
        text(string.format(_("%s of reading %s"), Data.fmtDuration(s.week_seconds), Theme.open_heart),
            Theme.face("script_bold", 22)),
        text(best and string.format(_("best day: %s %s"), os.date("%A", os.time{
                year = tonumber(best.date:sub(1, 4)), month = tonumber(best.date:sub(6, 7)),
                day = tonumber(best.date:sub(9, 10)), hour = 12 }), Theme.heart)
            or _("a fresh week to bloom ✿"),
            Theme.face("script", 16), { color = Theme.soft_ink }),
    }
    local flowers = {}
    for i, read in ipairs(s.flowers) do flowers[i] = read and Theme.flower or "·" end
    local garden = VerticalGroup:new{
        align = "center",
        text(table.concat(flowers, " "), Theme.face("ui", 18), { max_width = self.inner_w }),
        text(_("my last 14 days"), Theme.face("script", 14), { color = Theme.soft_ink }),
    }

    local group = VerticalGroup:new{
        align = "center",
        headline,
        VerticalSpan:new{ width = gap },
        self:weekChart(),
        VerticalSpan:new{ width = gap },
        garden,
        VerticalSpan:new{ width = gap },
    }

    local week = self:period("week", self.loadWeek)
    local company = text(_("Books that kept me company ♡"), Theme.face("script_bold", 18))
    table.insert(group, company)
    table.insert(group, vspan(6))
    if week.books == 0 then
        table.insert(group, text(_("No books yet this week ✿"), Theme.face("script", 16), { color = Theme.soft_ink }))
        return group
    end
    local shown = math.min(WEEK_TILES, week.books)
    local avail = self.content_h - group:getSize().h - px(24)
    local cover_w, cover_h = self:coverSize(WEEK_TILES, gap, avail)
    if cover_h < px(50) then
        -- Too little room for covers: a sweet list instead.
        for i = 1, shown do
            local b = week.list[i]
            table.insert(group, text(string.format("%s %s · %s", Theme.flower, b.title, Data.fmtDuration(b.seconds)),
                Theme.face("script", 16), { max_width = self.inner_w }))
        end
    else
        table.insert(group, self:tileRow(week.list, 1, shown, cover_w, cover_h, gap))
    end
    if week.books > shown then
        table.insert(group, text(string.format(_("+%d more %s"), week.books - shown, Theme.open_heart),
            Theme.face("script", 14), { color = Theme.soft_ink }))
    end
    return group
end

function BlossomView:build_books()
    local s = self.stats
    if #s.recent == 0 then
        return self:emptyState(_("No books on your shelf yet ✿\nOpen a book and it will bloom here."))
    end
    local gap = px(8)
    local n = #s.recent
    local chrome = 2 * (Size.padding.default + Size.border.thin)
    local row_h = math.min(px(96), floor((self.content_h - gap * (n - 1)) / n) - chrome)
    local inner = cardInner(self.inner_w)
    local glyph_w = px(36)
    local body_w = inner - glyph_w
    local group = VerticalGroup:new{ align = "center" }
    for i, b in ipairs(s.recent) do
        local pct = floor(b.progress * 100 + 0.5)
        local status = b.finished
            and string.format(_("finished %s · %s"), Theme.heart, Data.fmtDuration(b.seconds))
            or string.format("%d%% · %s", pct, Data.fmtDuration(b.seconds))
        local status_w = floor(body_w * 0.38)
        local body = VerticalGroup:new{
            align = "left",
            text(b.title, Theme.face("bold", 17), { max_width = body_w }),
            text(b.authors ~= "" and b.authors or " ", Theme.face("script", 15),
                { color = Theme.soft_ink, max_width = body_w }),
            vspan(4),
            HorizontalGroup:new{
                align = "center",
                ProgressWidget:new{
                    width = body_w - status_w - px(8),
                    height = px(12),
                    percentage = b.progress,
                    radius = px(6),
                    margin_h = 0,
                    margin_v = 0,
                    bordersize = Size.border.thin,
                    bordercolor = Theme.accent,
                    bgcolor = Theme.bg,
                    fillcolor = Theme.accent,
                },
                hspan(px(8)),
                text(status, Theme.face("script", 14), { max_width = status_w }),
            },
        }
        if i > 1 then table.insert(group, VerticalSpan:new{ width = gap }) end
        table.insert(group, Theme.card(HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = glyph_w, h = row_h },
                text(b.finished and Theme.heart or (i % 2 == 1 and Theme.flower or Theme.blossom),
                    Theme.face("ui", 24), { color = Theme.accent }),
            },
            body,
        }))
    end
    return group
end

function BlossomView:build_month()
    local gap = px(10)
    local key = string.format("%04d-%02d", self.year, self.month)
    local month = self:period(key, function() return self.loadMonth(self.year, self.month) end)
    local is_current = self.year == self.this_year and self.month == self.this_month

    local function nav(glyph, enabled, delta)
        return Button:new{
            text = glyph,
            bordersize = 0,
            width = px(60),
            text_font_size = 28,
            enabled = enabled,
            callback = function() self:shiftMonth(delta) end,
            show_parent = self,
        }
    end
    local title_w = self.inner_w - 2 * px(60)
    local switcher = HorizontalGroup:new{
        align = "center",
        nav("‹", true, -1),
        CenterContainer:new{
            dimen = Geom:new{ w = title_w, h = px(40) },
            text(Data.monthTitle(self.year, self.month), Theme.face("script_bold", 22), { max_width = title_w }),
        },
        nav("›", not is_current, 1),
    }
    local summary = string.format(_("%s · %d pages · %d days · %d books"),
        Data.fmtDuration(month.seconds), month.pages, month.days_read, month.books)
    local pill = Theme.card(CenterContainer:new{
        dimen = Geom:new{ w = cardInner(self.inner_w), h = px(30) },
        text(summary, Theme.face("script", 16), { max_width = cardInner(self.inner_w) }),
    }, { radius = px(18) })

    local group = VerticalGroup:new{
        align = "center",
        switcher,
        pill,
        VerticalSpan:new{ width = gap },
    }
    if month.books == 0 then
        table.insert(group, vspan(30))
        table.insert(group, text(_("No blooms this month ✿"), Theme.face("script", 22), { color = Theme.soft_ink }))
        return group
    end

    local max_tiles = MONTH_COLS * MONTH_ROWS
    local shown = math.min(max_tiles, month.books)
    local more_h = month.books > shown and px(24) or 0
    local rows = math.ceil(shown / MONTH_COLS)
    local avail = floor((self.content_h - group:getSize().h - more_h) / MONTH_ROWS) - gap
    local cover_w, cover_h = self:coverSize(MONTH_COLS, gap, avail)
    for r = 1, rows do
        local from = (r - 1) * MONTH_COLS + 1
        if r > 1 then table.insert(group, VerticalSpan:new{ width = gap }) end
        table.insert(group, self:tileRow(month.list, from, math.min(shown, from + MONTH_COLS - 1), cover_w, cover_h, gap))
    end
    if month.books > shown then
        table.insert(group, text(string.format(_("+%d more %s"), month.books - shown, Theme.open_heart),
            Theme.face("script", 16), { color = Theme.soft_ink }))
    end
    return group
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

return BlossomView
