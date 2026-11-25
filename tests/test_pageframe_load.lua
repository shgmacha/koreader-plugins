-- Loads Page Frame's main.lua the way KOReader's PluginLoader does (dofile, path, _meta.lua
-- fields copied onto the module) against stubbed KOReader modules, then drives it like a
-- ReaderUI would: menu, painting, margins, font CSS, the toggle action.
local H = require("tests.harness")
local ffi = require("ffi")
local test, eq = H.test, H.eq

local PLUGIN_DIR = "./pageframe.koplugin"
local DATA_DIR = "/data"
local SCREEN_W, SCREEN_H = 240, 320
local BORDER = 4 -- px of ink around the edge of the fake frame image

local W -- the fake world, rebuilt by fresh()

local function class()
    local C = {}
    C.__index = C
    function C:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function C:new(o) o = setmetatable(o or {}, self); if o.init then o:init() end; return o end
    return C
end

-- A fake BlitBuffer backed by an FFI byte array.
local function fakeBB(w, h, bb_type, bpp)
    local bb = {
        w = w, h = h, bb_type = bb_type,
        stride = w * bpp,
        data = ffi.new("uint8_t[?]", w * h * bpp),
        freed = false,
    }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:getType() return self.bb_type end
    function bb:getRotation() return 0 end
    function bb:free() self.freed = true end
    return bb
end

local TYPE_BB8, TYPE_BB8A, TYPE_BBRGB32 = 1, 2, 5

-- The decoded frame: transparent, with an opaque black ring BORDER px wide.
local function ringImage(w, h)
    local bb = fakeBB(w, h, TYPE_BBRGB32, 4)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local b = W.border or BORDER
            local speck = W.speck and x >= W.speck[1] and x < W.speck[1] + 3 and y >= W.speck[2] and y < W.speck[2] + 3
            if speck or x < b or y < b or x >= w - b or y >= h - b then
                bb.data[(y * w + x) * 4 + 3] = 255 -- r = g = b = 0, alpha 255
            end
        end
    end
    return bb
end

-- An in-memory folder for the frame cache (pageframe_cache's fs interface).
local function cacheFs(files)
    local clock = 0
    local fs = { saves = 0 }
    function fs.open(path, mode)
        if mode:sub(1, 1) == "r" then
            local data = files[path]
            if not data then return nil end
            local pos = 1
            return {
                read = function(_, what)
                    if pos > #data then return nil end
                    if what == "*l" then
                        local nl = data:find("\n", pos, true) or (#data + 1)
                        local line = data:sub(pos, nl - 1)
                        pos = nl + 1
                        return line
                    end
                    local chunk = data:sub(pos, pos + what - 1)
                    pos = pos + #chunk
                    return chunk
                end,
                close = function() return true end,
            }
        end
        if W.cache_unwritable then return nil end
        local parts = {}
        return {
            write = function(_, x) parts[#parts + 1] = x; return true end,
            close = function() clock = clock + 1; files[path] = table.concat(parts); return true end,
        }
    end
    function fs.rename(a, b)
        if not files[a] then return false end
        files[b], files[a] = files[a], nil
        fs.saves = fs.saves + 1
        return true
    end
    function fs.remove(p) files[p] = nil; return true end
    function fs.mkdir() end
    function fs.list(dir)
        local out = {}
        for p in pairs(files) do
            local name = p:sub(#dir + 2)
            if p:sub(1, #dir + 1) == dir .. "/" and not name:find("/") then out[#out + 1] = name end
        end
        return out
    end
    function fs.mtime() return clock end
    return fs
end

-- Margin fitting and the frame font are opt-in since 1.2.0; tests of those features turn them on.
local OPTED_IN = { fit_text = true, font = "Cormorant Garamond", italic = true, schema = 2 }

local function fresh(opts)
    opts = opts or {}
    if opts.opted_in then
        opts.settings = opts.settings or {}
        local pf = opts.settings.pageframe or {}
        for k, v in pairs(OPTED_IN) do if pf[k] == nil then pf[k] = v end end
        opts.settings.pageframe = pf
    end
    W = {
        settings = opts.settings or {},
        notified = {}, dirty = {}, ticks = {}, registered_fonts = {},
        decoded = {}, decode_fails = opts.decode_fails,
        -- koreader/frames/: the user's frames (no frame ships with the plugin)
        custom_files = opts.custom_files or (not opts.no_frames and { "Rose garland.webp" }) or nil,
        footer_h = 0, footer_visible = false, reclaim = false,
    }

    W.shown, W.closed, W.online, W.restarted = {}, {}, opts.online or false, false
    W.update = { cleaned = {}, checks = 0, installs = {},
                 check_result = opts.check_result or {}, install_result = opts.install_result or { "9.9.9" } }
    local UIManager = {}
    function UIManager:setDirty(w, mode) table.insert(W.dirty, mode) end
    function UIManager:nextTick(f) table.insert(W.ticks, f) end
    function UIManager:scheduleIn(_, f) table.insert(W.ticks, f) end
    function UIManager:show(w) table.insert(W.shown, w) end
    function UIManager:close(w) table.insert(W.closed, w) end
    function UIManager:forceRePaint() end
    function UIManager:restartKOReader() W.restarted = true end
    W.flush = function()
        while #W.ticks > 0 do table.remove(W.ticks, 1)() end
    end

    local lfs = {
        attributes = function(path, what)
            if what == nil then
                -- A frame image's size and modification time (part of the cache key).
                if path:match("^" .. DATA_DIR .. "/frames/") then
                    return { mode = "file", size = 1000, modification = W.image_mtime }
                end
                return nil
            end
            if path == PLUGIN_DIR .. "/fonts" then return "directory" end
            if path == DATA_DIR .. "/frames" and W.custom_files then return "directory" end
            return nil
        end,
        dir = function(path)
            local files = { ".", ".." }
            if path == PLUGIN_DIR .. "/fonts" then
                for _, f in ipairs({ "CormorantGaramond-Italic.otf", "._CormorantGaramond-Italic.otf", "CormorantGaramond-Regular.otf", "OFL.txt" }) do
                    files[#files + 1] = f
                end
            elseif path == DATA_DIR .. "/frames" then
                for _, f in ipairs(W.custom_files or {}) do files[#files + 1] = f end
            end
            local i = 0
            return function() i = i + 1; return files[i] end
        end,
    }

    local stubs = {
        ["ffi/blitbuffer"] = {
            TYPE_BB8 = TYPE_BB8, TYPE_BB8A = TYPE_BB8A, TYPE_BBRGB32 = TYPE_BBRGB32,
            COLOR_BLACK = "black",
            new = function(w, h, t)
                assert(t == TYPE_BB8, "mask must be BB8")
                local bb = fakeBB(w, h, t, 1)
                table.insert(W.masks, bb)
                return bb
            end,
        },
        ["datastorage"] = { getDataDir = function() return DATA_DIR end },
        ["device"] = { screen = {
            getWidth = function() return SCREEN_W end,
            getHeight = function() return SCREEN_H end,
            scaleBySize = function(_, v) return math.ceil(v * 1.0) end,
        } },
        ["dispatcher"] = { registerAction = function(_, id, def) W.action = { id = id, def = def } end },
        ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
        ["ui/widget/notification"] = { notify = function(_, text) table.insert(W.notified, text) end },
        ["ui/renderimage"] = {
            renderImageFile = function(_, path, want_frames, w, h)
                table.insert(W.decoded, { path = path, w = w, h = h })
                if W.decode_fails then return nil end
                return ringImage(w, h)
            end,
            scaleBlitBuffer = function(_, bb) return bb end,
        },
        ["ui/uimanager"] = UIManager,
        ["ui/widget/infomessage"] = { new = function(_, o) o.kind = "info"; return o end },
        ["ui/widget/confirmbox"] = { new = function(_, o) o.kind = "confirm"; return o end },
        ["ui/network/manager"] = {
            isOnline = function() return W.online end,
            runWhenOnline = function(_, fn) W.ran_online = true; fn() end,
        },
        ["pageframe_update"] = {
            cleanup = function(dir) table.insert(W.update.cleaned, dir) end,
            check = function(version)
                W.update.checks = W.update.checks + 1
                W.update.checked_version = version
                if W.update.check_crash then error("boom") end
                return W.update.check_result[1], W.update.check_result[2]
            end,
            install = function(info, dir)
                table.insert(W.update.installs, { info = info, dir = dir })
                if W.update.install_crash then error("disk on fire") end
                return W.update.install_result[1], W.update.install_result[2]
            end,
        },
        -- Runs the task inline (the real runner forks; it has its own tests).
        ["pageframe_background"] = { run = function(task, on_done)
            local res = { n = 0 }
            local function pack(...) res = { n = select("#", ...), ... } end
            pack(pcall(task))
            on_done(unpack(res, 1, res.n))
        end },
        ["ui/widget/container/widgetcontainer"] = class(),
        ["libs/libkoreader-lfs"] = lfs,
        ["libs/libkoreader-cre"] = {
            registerFont = function(path) table.insert(W.registered_fonts, path) end,
            getFontFaces = function() return { "Noto Serif", "Cormorant Garamond", "Literata" } end,
        },
        ["logger"] = { dbg = function() end, info = function() end, warn = function(...) W.warned = { ... } end },
        ["gettext"] = function(s) return s end,
        ["ffi/util"] = { template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end },
    }
    for name, mod in pairs(stubs) do
        package.loaded[name] = nil
        package.preload[name] = function() return mod end
    end
    package.loaded["pageframe_core"] = nil
    package.loaded["pageframe_cache"] = nil
    W.image_mtime = 1
    -- koreader/cache/pageframe, in memory; survives fresh() only if passed in (a "second session").
    W.cache_files = opts.cache_files or {}
    W.cache_fs = cacheFs(W.cache_files)
    W.masks = {}

    _G.G_reader_settings = {
        readSetting = function(_, k) return W.settings[k] end,
        saveSetting = function(_, k, v) W.settings[k] = v end,
    }

    -- PluginLoader: dofile main.lua with the plugin dir on package.path, set path, copy meta.
    local saved_path = package.path
    package.path = PLUGIN_DIR .. "/?.lua;" .. package.path
    local Plugin = dofile(PLUGIN_DIR .. "/main.lua")
    Plugin.path = PLUGIN_DIR
    for k, v in pairs(dofile(PLUGIN_DIR .. "/_meta.lua")) do
        if k ~= "name" then Plugin[k] = v end
    end
    -- Like PluginLoader, keep the plugin folder on package.path (modules are required lazily).
    package.path = saved_path
    if not package.path:find(PLUGIN_DIR .. "/?.lua", 1, true) then
        package.path = package.path .. ";" .. PLUGIN_DIR .. "/?.lua"
    end
    Plugin._cache_fs = W.cache_fs
    W.Plugin = Plugin
    return W
end

-- A ReaderUI with just what Page Frame touches.
local function newReader(opts)
    opts = opts or {}
    local doc_store = opts.doc_store or {}
    local ui = { events = {} }
    ui.dialog = ui
    ui.document = { configurable = opts.configurable or {
        h_page_margins = { 15, 15 }, t_page_margin = 15, b_page_margin = 15,
    } }
    ui.doc_settings = {
        readSetting = function(_, k) return doc_store[k] end,
        saveSetting = function(_, k, v) doc_store[k] = v end,
        delSetting = function(_, k) doc_store[k] = nil end,
    }
    ui.doc_store = doc_store
    if opts.paged then ui.paging = {} else ui.rolling = {} end
    ui.typeset = {}
    ui.styletweak = { getCssText = function() return opts.tweak_css end }
    ui.view = {
        footer = {
            getHeight = function() return W.footer_h end,
            settings = setmetatable({}, { __index = function(_, k)
                if k == "reclaim_height" then return W.reclaim end
            end }),
        },
        registerViewModule = function(self, name, widget) self.modules = self.modules or {}; self.modules[name] = widget end,
    }
    setmetatable(ui.view, { __index = function(_, k) if k == "footer_visible" then return W.footer_visible end end })
    ui.menu = { registerToMainMenu = function(_, plugin) ui.menu_items = {}; plugin:addToMainMenu(ui.menu_items) end }
    function ui:handleEvent(ev)
        table.insert(self.events, ev)
        if ev.name == "SetPageMargins" then self.applied_margins = ev.args[1] end
    end
    ui.plugin = W.Plugin:new{ ui = ui }
    return ui
end

local function eventNames(ui)
    local out = {}
    for _, ev in ipairs(ui.events) do out[#out + 1] = ev.name end
    return out
end

local function countEvents(ui, name)
    local n = 0
    for _, ev in ipairs(ui.events) do if ev.name == name then n = n + 1 end end
    return n
end

local function menu(ui) return ui.menu_items.pageframe.sub_item_table_func() end

local function menuItem(items, text)
    for _, item in ipairs(items) do
        local t = item.text or (item.text_func and item.text_func())
        if t == text or (t and t:find(text, 1, true) == 1) then return item end
    end
end

local function paint(ui)
    local calls = {}
    local bb = { colorblitFrom = function(_, src, x, y, ox, oy, w, h, color)
        table.insert(calls, { src = src, x = x, y = y, w = w, h = h, color = color })
    end }
    ui.view.modules.pageframe:paintTo(bb, 0, 0)
    return calls
end

local function margins(ui)
    local c = ui.document.configurable
    return { c.h_page_margins[1], c.t_page_margin, c.h_page_margins[2], c.b_page_margin }
end

-- Expected fitted margins: ring BORDER px = 1 cell, + 3 cells gap = 4 cells = 32 px each side.
local FIT = { 32, 32, 32, 32 }

-- Loading -----------------------------------------------------------------------

test("loads like KOReader: meta fields copied, no method shadowed", function()
    fresh()
    eq(W.Plugin.fullname, "Page Frame")
    eq(type(W.Plugin.version), "string")
    eq(type(W.Plugin.description), "string")
    local ui = newReader()
    assert(ui.plugin, "instance created")
    assert(ui.view.modules.pageframe, "view module registered")
    eq(W.action.id, "pageframe_toggle")
    eq(W.action.def.event, "TogglePageFrame")
end)

test("default settings: first frame, soft, crisp, margins widened only if needed, your font", function()
    fresh()
    local ui = newReader()
    local s = ui.plugin.settings
    eq({ s.frame, s.darkness, s.fit_text, s.font, s.italic, s.crisp, s.enabled },
        { nil, "soft", true, "keep", false, true, true })
end)

test("by default: your margins widened only where the frame needs it, and no font CSS", function()
    fresh()
    local ui = newReader({ tweak_css = "p { margin: 0 }" })
    ui.plugin:onReaderReady(); W.flush()
    eq(#paint(ui), 1)
    eq(margins(ui), FIT) -- your 15s are narrower than the frame needs (32) on every side
    eq(ui.doc_store.pageframe_margins, { saved = { 15, 15, 15, 15 }, applied = FIT })
    eq(countEvents(ui, "ApplyStyleSheet"), 0)
    eq(ui.styletweak:getCssText(), "p { margin: 0 }")
end)

test("a side where your margin is already wider than needed keeps your margin", function()
    fresh()
    local ui = newReader({ configurable = { h_page_margins = { 50, 15 }, t_page_margin = 40, b_page_margin = 15 } })
    ui.plugin:onReaderReady(); W.flush()
    eq(margins(ui), { 50, 40, 32, 32 })
end)

test("margins that already clear the frame are left completely alone", function()
    fresh()
    local ui = newReader({ configurable = { h_page_margins = { 60, 60 }, t_page_margin = 60, b_page_margin = 60 } })
    ui.plugin:onReaderReady(); W.flush()
    eq(margins(ui), { 60, 60, 60, 60 })
    eq(countEvents(ui, "SetPageMargins"), 0)
    eq(ui.doc_store.pageframe_margins, nil)
end)

test("widening a margin by hand while the frame is on becomes your new margin", function()
    fresh()
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    ui.document.configurable.h_page_margins = { 70, 32 } -- you widened the left side yourself
    ui.plugin:refit()
    eq(margins(ui), { 70, 32, 32, 32 })
    eq(ui.doc_store.pageframe_margins, nil) -- nothing of ours left to undo
end)

test("1.1.0 setups move once to: your font, margins widened only if needed", function()
    fresh({ settings = { pageframe = { fit_text = false, font = "Cormorant Garamond", italic = true, darkness = "bold" } } })
    local ui = newReader()
    local s = ui.plugin.settings
    eq({ s.fit_text, s.font, s.italic, s.schema, s.darkness }, { true, "keep", false, 2, "bold" })
end)

test("...and choices made after that stick (the move happens only once)", function()
    fresh({ settings = { pageframe = { fit_text = true, font = "Literata", italic = true, schema = 2 } } })
    local s = newReader().plugin.settings
    eq({ s.fit_text, s.font, s.italic }, { true, "Literata", true })
end)

test("a book 1.1.0 fitted keeps clear margins and still remembers your own", function()
    fresh({ settings = { pageframe = { fit_text = true, font = "Cormorant Garamond", italic = true } } })
    local store = { pageframe_margins = { saved = { 15, 15, 15, 15 }, applied = FIT } }
    local ui = newReader({ doc_store = store, configurable = {
        h_page_margins = { FIT[1], FIT[3] }, t_page_margin = FIT[2], b_page_margin = FIT[4] } })
    ui.plugin:onReaderReady(); W.flush()
    eq(margins(ui), FIT)
    eq(countEvents(ui, "SetPageMargins"), 0)
    menuItem(menu(ui), "Show page frame").callback()
    eq(margins(ui), { 15, 15, 15, 15 })
end)

test("the default frame isn't saved until one is picked", function()
    fresh()
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    eq(W.settings.pageframe and W.settings.pageframe.frame, nil)
end)

test("1.0.0's built-in frame id falls back to the first frame in koreader/frames", function()
    fresh({ settings = { pageframe = { frame = "builtin:rose-garland", darkness = "bold" } } })
    local ui = newReader()
    eq(ui.plugin.settings.frame, nil)
    eq(ui.plugin.settings.darkness, "bold")
    eq(ui.plugin:currentFrame().id, "custom:Rose garland.webp")
end)

test("no frames installed: nothing painted, the switch greyed out, a hint in the menu", function()
    fresh({ no_frames = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    eq(#paint(ui), 0)
    eq(countEvents(ui, "SetPageMargins"), 0)
    local items = menu(ui)
    eq(items[1].text, "Show page frame")
    eq(items[1].checked_func(), false)
    eq(items[1].enabled_func(), false)
    eq(items[2].text, "Add frame images to koreader/frames/")
    eq(items[2].enabled_func(), false)
    eq(items[2].separator, true)
    eq(ui.styletweak:getCssText(), nil) -- no frame, so no font CSS either
end)

-- Where the plugin shows up -------------------------------------------------------

-- The file browser: no document, no view, no typesetting — just the main menu.
local function newFileManager()
    local fm = { events = {} }
    function fm:handleEvent(ev) table.insert(self.events, ev) end
    fm.menu = { registerToMainMenu = function(_, plugin) fm.menu_items = {}; plugin:addToMainMenu(fm.menu_items) end }
    fm.plugin = W.Plugin:new{ ui = fm }
    return fm
end

test("Page frame is in the Tools menu and the typeset tab while reading", function()
    fresh()
    local ui = newReader()
    eq(ui.menu_items.pageframe.sorting_hint, "tools")
    eq(ui.menu_items.pageframe.text, "Page frame")
    eq(ui.menu_items.pageframe_typeset.sorting_hint, "typeset")
    eq(ui.menu_items.pageframe_typeset.text, "Page frame")
    -- both open the same menu
    local a, b = ui.menu_items.pageframe.sub_item_table_func(), ui.menu_items.pageframe_typeset.sub_item_table_func()
    eq(#a, #b)
    eq(a[1].text, "Show page frame")
    eq(b[1].text, "Show page frame")
    eq(W.Plugin.is_doc_only, false) -- loaded in the file browser too
end)

test("file browser: Page frame is in Tools there too, and the switch works", function()
    fresh({ custom_files = { "Rose garland.webp", "lace.png" } })
    local fm = newFileManager()
    eq(fm.menu_items.pageframe.sorting_hint, "tools")
    eq(fm.menu_items.pageframe_typeset, nil) -- the file browser has no typeset tab
    local items = fm.menu_items.pageframe.sub_item_table_func()
    local switch = menuItem(items, "Show page frame")
    eq({ switch.enabled_func(), switch.checked_func() }, { true, true })
    switch.callback()
    eq(W.settings.pageframe.enabled, false)
    eq(#W.dirty, 0) -- no book on screen to repaint
    eq(#fm.events, 0) -- no style sheet to re-apply
    fm.plugin:onTogglePageFrame()
    eq(W.settings.pageframe.enabled, true)
    menuItem(items, "lace").callback()
    eq(W.settings.pageframe.frame, "custom:lace.png")
end)

test("file browser: the book options can be set there, for the next book", function()
    fresh()
    local fm = newFileManager()
    local items = fm.menu_items.pageframe.sub_item_table_func()
    local keep = menuItem(items, "Keep text inside the frame")
    eq({ keep.enabled_func(), keep.checked_func() }, { true, true })
    keep.callback()
    eq(W.settings.pageframe.fit_text, false)
    local italic = menuItem(items, "Italic text")
    eq(italic.enabled_func(), true)
    italic.callback()
    eq(W.settings.pageframe.italic, true)
    eq(menuItem(items, "Font with the frame").enabled_func(), true)
    eq(#menuItem(items, "Font with the frame").sub_item_table_func() > 2, true)
    eq(W.update.cleaned, { PLUGIN_DIR }) -- update leftovers are still cleaned up
end)

test("file browser: nothing reader-only runs (no fonts registered, no view, no paint hook)", function()
    fresh()
    newFileManager()
    eq(#W.registered_fonts, 0)
end)

-- Menu --------------------------------------------------------------------------

test("menu: the Show page frame switch, then the frames in koreader/frames; the first is the default", function()
    fresh({ custom_files = { "Rose garland.webp", "lace.png", "notes.txt" } })
    local ui = newReader()
    local items = menu(ui)
    eq({ items[1].text, items[2].text, items[3].text }, { "Show page frame", "lace", "Rose garland" })
    eq(items[1].separator, true)
    eq(items[3].separator, true)
    eq({ items[1].checked_func(), items[1].enabled_func() }, { true, true })
    eq({ items[2].checked_func(), items[3].checked_func() }, { true, false })
    eq(menuItem(items, "None"), nil) -- the switch replaces None
end)

test("choosing a frame saves it, re-applies the CSS and marks the page dirty", function()
    fresh({ custom_files = { "lace.png" } })
    local ui = newReader()
    ui.plugin:onReaderReady()
    ui.events = {}
    menuItem(menu(ui), "lace").callback()
    eq(W.settings.pageframe.frame, "custom:lace.png")
    eq(countEvents(ui, "ApplyStyleSheet"), 1)
    eq(W.dirty[#W.dirty], "full")
end)

-- Painting ----------------------------------------------------------------------

test("no frame: nothing is painted", function()
    fresh({ settings = { pageframe = { frame = "none" } } })
    local ui = newReader()
    eq(#paint(ui), 0)
    eq(#W.decoded, 0)
end)

test("a frame is painted once per paint with a BB8 ink mask, decoded only once", function()
    fresh()
    local ui = newReader()
    local calls = paint(ui)
    eq(#calls, 1)
    eq({ calls[1].w, calls[1].h, calls[1].color }, { SCREEN_W, SCREEN_H, "black" })
    local mask = calls[1].src
    eq(mask:getType(), TYPE_BB8)
    eq(mask.data[0], 255)                                  -- corner: ring ink
    eq(mask.data[(SCREEN_H / 2) * mask.stride + SCREEN_W / 2], 0) -- middle: paper
    paint(ui)
    eq(#W.decoded, 1)
    eq(W.decoded[1].path, DATA_DIR .. "/frames/Rose garland.webp")
end)

test("crisp lines can be turned off, which rebuilds the mask", function()
    fresh()
    local ui = newReader()
    paint(ui)
    menuItem(menu(ui), "Crisp lines").callback()
    eq(W.settings.pageframe.crisp, false)
    paint(ui)
    eq(#W.decoded, 2)
end)

test("a stray dot inside the text area is erased from the drawing", function()
    fresh()
    W.speck = { 120, 160 } -- a 3x3 px dot in the middle of the page
    local ui = newReader()
    local mask = paint(ui)[1].src
    eq(mask.data[161 * mask.stride + 121], 0)
    eq(mask.data[0], 255) -- the frame itself is still drawn
end)

-- Frame cache ---------------------------------------------------------------------

local function cachedNames()
    local out = {}
    for path in pairs(W.cache_files) do out[#out + 1] = path:match("[^/]+$") end
    table.sort(out)
    return out
end

test("cache: the first open builds the frame and saves it to koreader/cache/pageframe", function()
    fresh()
    local ui = newReader()
    eq(#paint(ui), 1)
    eq(#W.decoded, 1)
    eq(W.cache_fs.saves, 1)
    local names = cachedNames()
    eq(#names, 1)
    assert(names[1]:match("%.pfm$"), names[1])
    local path = next(W.cache_files)
    eq(path:sub(1, #DATA_DIR + 17), DATA_DIR .. "/cache/pageframe/")
end)

test("cache: the next open loads it — no decode — and fits the same margins", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    local first_mask = paint(ui)[1].src
    local first_margins = margins(ui)
    local files = W.cache_files
    fresh({ cache_files = files, opted_in = true }) -- a later KOReader session
    local ui2 = newReader()
    ui2.plugin:onReaderReady(); W.flush()
    local calls = paint(ui2)
    eq(#W.decoded, 0)
    eq(#calls, 1)
    local mask = calls[1].src
    for _, i in ipairs({ 0, 5, SCREEN_W * 100 + 120, SCREEN_W * SCREEN_H - 1 }) do
        eq(mask.data[i], first_mask.data[i])
    end
    eq(margins(ui2), first_margins)
    eq(W.cache_fs.saves, 0) -- nothing rewritten
end)

test("cache: a darkness change builds and caches a second version", function()
    fresh()
    local ui = newReader()
    paint(ui)
    menuItem(menuItem(menu(ui), "Darkness").sub_item_table, "Bold").callback()
    paint(ui)
    eq(#W.decoded, 2)
    eq(#cachedNames(), 2)
end)

test("cache: a replaced frame image (new modification time) is rebuilt", function()
    fresh()
    paint(newReader())
    local files = W.cache_files
    fresh({ cache_files = files })
    W.image_mtime = 2
    paint(newReader())
    eq(#W.decoded, 1)
end)

test("cache: a damaged cache file is thrown away and rebuilt, never drawn", function()
    fresh()
    paint(newReader())
    local files = W.cache_files
    local path = next(files)
    files[path] = files[path]:sub(1, 200) -- truncated, as after a forced reset
    fresh({ cache_files = files })
    local calls = paint(newReader())
    eq(#W.decoded, 1)
    eq(#calls, 1)
    eq(#files[path] > 200, true) -- replaced by a good one
end)

test("cache: an unwritable cache folder still draws the frame", function()
    fresh()
    W.cache_unwritable = true
    local ui = newReader()
    eq(#paint(ui), 1)
    eq(#cachedNames(), 0)
    eq(#paint(ui), 1) -- and keeps using the in-memory copy
    eq(#W.decoded, 1)
end)

test("a frame that can't be decoded: one notification, no error, no retry", function()
    fresh({ decode_fails = true })
    local ui = newReader()
    eq(#paint(ui), 0)
    eq(#paint(ui), 0)
    eq(#W.notified, 1)
    eq(#W.decoded, 1)
    assert(W.notified[1]:find("Rose garland", 1, true))
end)

test("a chosen custom frame that was deleted: nothing painted, setting kept", function()
    fresh({ settings = { pageframe = { frame = "custom:gone.png" } } })
    local ui = newReader()
    eq(#paint(ui), 0)
    eq(ui.plugin.settings.frame, "custom:gone.png")
end)

test("the status bar's own room is left out of the frame area", function()
    fresh()
    W.footer_visible, W.footer_h = true, 40
    local ui = newReader()
    eq(paint(ui)[1].h, SCREEN_H - 40)
    W.reclaim = true
    eq(paint(ui)[1].h, SCREEN_H)
    eq(#W.decoded, 2)
    eq(W.masks[1].freed, true) -- the old mask is freed when rebuilt
end)

test("darkness changes rebuild the mask", function()
    fresh()
    local ui = newReader()
    paint(ui)
    menuItem(menuItem(menu(ui), "Darkness").sub_item_table, "Bold").callback()
    paint(ui)
    eq(#W.decoded, 2)
    eq(W.settings.pageframe.darkness, "bold")
end)

-- Margins -----------------------------------------------------------------------

test("on open, margins are fitted inside the frame and the originals saved", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady()
    W.flush()
    eq(margins(ui), FIT)
    eq(ui.applied_margins, FIT)
    eq(ui.typeset.unscaled_margins, FIT)
    eq(ui.doc_store.pageframe_margins, { applied = FIT, saved = { 15, 15, 15, 15 } })
    eq(countEvents(ui, "SetPageMargins"), 1)
end)

test("re-opening the book keeps the original margins saved and sends nothing", function()
    fresh({ opted_in = true })
    local store = {}
    local ui = newReader({ doc_store = store })
    ui.plugin:onReaderReady(); W.flush()
    local ui2 = newReader({ doc_store = store, configurable = ui.document.configurable })
    ui2.plugin:onReaderReady(); W.flush()
    eq(store.pageframe_margins.saved, { 15, 15, 15, 15 })
    eq(countEvents(ui2, "SetPageMargins"), 0)
end)

test("switching the frame off puts the book's margins back", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    menuItem(menu(ui), "Show page frame").callback()
    eq(margins(ui), { 15, 15, 15, 15 })
    eq(ui.doc_store.pageframe_margins, nil)
end)

test("margins changed by hand are kept when the frame goes away", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    ui.document.configurable.t_page_margin = 50 -- the user's own change
    menuItem(menu(ui), "Show page frame").callback()
    eq(margins(ui), { 32, 50, 32, 32 })
    eq(ui.doc_store.pageframe_margins, nil)
end)

test("turning off Keep text inside restores, turning it on fits again", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    local item = menuItem(menu(ui), "Keep text inside the frame")
    item.callback()
    eq(margins(ui), { 15, 15, 15, 15 })
    item.callback()
    eq(margins(ui), FIT)
end)

test("a mask rebuilt after the reader is ready re-fits once, on the next tick", function()
    fresh()
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    W.footer_visible, W.footer_h = true, 40
    paint(ui)
    eq(#W.ticks, 1)
    paint(ui)
    eq(#W.ticks, 1) -- not scheduled twice
    W.flush()
    eq(#W.ticks, 0)
end)

test("a re-fit with new margins keeps the book's original margins saved", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    -- The frame area changes (status bar shown) and the new frame image has a thicker border:
    -- 12 px = 2 cells, + 3 cells gap = 40 px each side.
    W.border, W.footer_visible, W.footer_h = 12, true, 40
    paint(ui); W.flush()
    eq(margins(ui), { 40, 40, 40, 40 })
    eq(ui.doc_store.pageframe_margins, { applied = { 40, 40, 40, 40 }, saved = { 15, 15, 15, 15 } })
    menuItem(menu(ui), "Show page frame").callback()
    eq(margins(ui), { 15, 15, 15, 15 })
end)

-- Paged documents ---------------------------------------------------------------

test("paged documents: frame painted, no margins, no font, items disabled", function()
    fresh()
    local ui = newReader({ paged = true })
    ui.plugin:onReaderReady(); W.flush()
    eq(#paint(ui), 1)
    eq(countEvents(ui, "SetPageMargins"), 0)
    eq(ui.doc_store.pageframe_margins, nil)
    eq(ui.styletweak.getCssText(ui.styletweak), nil) -- not wrapped
    local items = menu(ui)
    eq(menuItem(items, "Keep text inside the frame").enabled_func(), false)
    eq(menuItem(items, "Font with the frame").enabled_func(), false)
    eq(menuItem(items, "Italic text").enabled_func(), false)
    menuItem(items, "Show page frame").callback()
    eq(countEvents(ui, "ApplyStyleSheet"), 0)
    eq(#paint(ui), 0)
end)

-- Font --------------------------------------------------------------------------

test("fonts are registered once per session, from the plugin's fonts folder, skipping macOS ._ files", function()
    fresh()
    newReader()
    newReader()
    eq(W.registered_fonts, {
        PLUGIN_DIR .. "/fonts/CormorantGaramond-Italic.otf",
        PLUGIN_DIR .. "/fonts/CormorantGaramond-Regular.otf",
    })
end)

test("the style CSS gets the frame font while a frame is on", function()
    fresh({ opted_in = true })
    local ui = newReader({ tweak_css = "p { margin: 0 }" })
    local css = ui.styletweak:getCssText()
    assert(css:find("^p { margin: 0 }\n"), css)
    assert(css:find('font-family: "Cormorant Garamond"', 1, true))
    assert(css:find("font-style: italic", 1, true))
    menuItem(menu(ui), "Show page frame").callback()
    eq(ui.styletweak:getCssText(), "p { margin: 0 }")
end)

test("font menu: keep, included, then installed fonts; choosing sends ApplyStyleSheet", function()
    fresh({ opted_in = true })
    local ui = newReader()
    local fonts = menuItem(menu(ui), "Font with the frame").sub_item_table_func()
    local texts = {}
    for i, f in ipairs(fonts) do texts[i] = f.text end
    eq(texts, { "Keep the book's font", "Cormorant Garamond (included)", "Literata", "Noto Serif" })
    eq(fonts[2].checked_func(), true)
    fonts[4].callback()
    eq(W.settings.pageframe.font, "Noto Serif")
    eq(countEvents(ui, "ApplyStyleSheet"), 1)
    assert(ui.styletweak:getCssText():find('"Noto Serif"', 1, true))
    fonts[1].callback()
    assert(not ui.styletweak:getCssText():find("font-family", 1, true))
end)

test("italic can be turned off", function()
    fresh({ opted_in = true })
    local ui = newReader()
    menuItem(menu(ui), "Italic text").callback()
    eq(W.settings.pageframe.italic, false)
    eq(countEvents(ui, "ApplyStyleSheet"), 1)
    assert(not ui.styletweak:getCssText():find("italic", 1, true))
end)

-- Toggle ------------------------------------------------------------------------

test("toggle gesture flips the switch, keeping the chosen frame", function()
    fresh({ custom_files = { "Rose garland.webp", "lace.png" } })
    local ui = newReader()
    menuItem(menu(ui), "Rose garland").callback()
    eq(ui.plugin:onTogglePageFrame(), true)
    eq({ W.settings.pageframe.enabled, W.settings.pageframe.frame }, { false, "custom:Rose garland.webp" })
    eq(#paint(ui), 0)
    ui.plugin:onTogglePageFrame()
    eq({ W.settings.pageframe.enabled, W.settings.pageframe.frame }, { true, "custom:Rose garland.webp" })
    eq(#paint(ui), 1)
end)

test("toggle: with no frames installed, nothing happens", function()
    fresh({ no_frames = true })
    local ui = newReader()
    eq(ui.plugin:onTogglePageFrame(), true)
    eq(W.settings.pageframe, nil)
end)

-- Show page frame -----------------------------------------------------------------

test("switching off hides the frame, drops its font and gives the book its margins back", function()
    fresh({ opted_in = true })
    local ui = newReader({ tweak_css = "p { margin: 0 }" })
    ui.plugin:onReaderReady(); W.flush()
    eq(margins(ui), FIT)
    menuItem(menu(ui), "Show page frame").callback()
    eq(W.settings.pageframe.enabled, false)
    eq(#paint(ui), 0)
    eq(ui.styletweak:getCssText(), "p { margin: 0 }")
    eq(margins(ui), { 15, 15, 15, 15 })
    eq(menuItem(menu(ui), "Show page frame").checked_func(), false)
    eq(menuItem(menu(ui), "Rose garland").checked_func(), true) -- the chosen frame is kept
end)

test("switching back on restores the frame, font and fitted margins", function()
    fresh({ opted_in = true })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    menuItem(menu(ui), "Show page frame").callback()
    menuItem(menu(ui), "Show page frame").callback()
    eq(W.settings.pageframe.enabled, true)
    eq(#paint(ui), 1)
    assert(ui.styletweak:getCssText():find("Cormorant", 1, true))
    eq(margins(ui), FIT)
end)

test("choosing a frame while switched off switches it on", function()
    fresh({ custom_files = { "Rose garland.webp", "lace.png" } })
    local ui = newReader()
    menuItem(menu(ui), "Show page frame").callback()
    menuItem(menu(ui), "lace").callback()
    eq({ W.settings.pageframe.enabled, W.settings.pageframe.frame }, { true, "custom:lace.png" })
    eq(#paint(ui), 1)
end)

test("starting switched off: nothing drawn, no CSS, no margins touched", function()
    fresh({ settings = { pageframe = { enabled = false } } })
    local ui = newReader()
    ui.plugin:onReaderReady(); W.flush()
    eq(#paint(ui), 0)
    eq(ui.styletweak:getCssText(), nil)
    eq(countEvents(ui, "SetPageMargins"), 0)
end)

test("1.1.0's None becomes switched off, remembering the last frame", function()
    fresh({ custom_files = { "Rose garland.webp", "lace.png" },
            settings = { pageframe = { frame = "none", last_frame = "custom:lace.png" } } })
    local ui = newReader()
    local s = ui.plugin.settings
    eq({ s.enabled, s.frame, s.last_frame }, { false, "custom:lace.png", nil })
    eq(#paint(ui), 0)
    menuItem(menu(ui), "Show page frame").callback()
    eq(ui.plugin:shownFrame().id, "custom:lace.png")
end)

test("1.1.0's None with nothing remembered: off, and on shows the first frame", function()
    fresh({ settings = { pageframe = { frame = "none" } } })
    local ui = newReader()
    eq({ ui.plugin.settings.enabled, ui.plugin.settings.frame }, { false, nil })
    ui.plugin:onTogglePageFrame()
    eq(ui.plugin:shownFrame().id, "custom:Rose garland.webp")
end)

test("closing the book frees the mask", function()
    fresh()
    local ui = newReader()
    paint(ui)
    ui.plugin:onCloseDocument()
    eq(W.masks[1].freed, true)
end)

-- Updates -----------------------------------------------------------------------

local function lastShown() return W.shown[#W.shown] end

test("on start, leftovers of an earlier update are cleaned up", function()
    fresh()
    newReader()
    eq(W.update.cleaned, { PLUGIN_DIR })
end)

test("the menu shows the installed version on Check for updates", function()
    fresh()
    local ui = newReader()
    local item = menuItem(menu(ui), "Check for updates (")
    eq(item.text_func(), "Check for updates (v" .. W.Plugin.version .. ")")
    eq(item.keep_menu_open, true)
end)

test("check for updates: up to date says so and records the time", function()
    fresh()
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    eq(W.ran_online, true)
    eq(W.update.checked_version, W.Plugin.version)
    eq(W.shown[1].text, "Looking for updates…")
    eq(W.closed[1], W.shown[1])
    eq(lastShown().text, "You have the latest Page Frame (v" .. W.Plugin.version .. ").")
    assert(W.settings.pageframe.last_update_check, "time recorded")
end)

test("check for updates: a newer version asks, Update installs, then offers a restart", function()
    fresh({ check_result = { { version = "9.9.9", zip_url = "z" } } })
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    local ask = lastShown()
    eq(ask.kind, "confirm")
    assert(ask.text:find("Page Frame v9.9.9 is ready", 1, true), ask.text)
    eq(ask.ok_text, "Update")
    ask.ok_callback()
    eq(W.update.installs[1].dir, PLUGIN_DIR)
    eq(W.update.installs[1].info.version, "9.9.9")
    local restart = lastShown()
    assert(restart.text:find("Updated to v9.9.9", 1, true), restart.text)
    restart.ok_callback()
    eq(W.restarted, true)
end)

test("check for updates: no connection shows the network message", function()
    fresh({ check_result = { nil, "network" } })
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    eq(lastShown().text, "Couldn't reach GitHub. Check Wi-Fi and try again.")
end)

test("check for updates: a crashing check is reported as a network problem", function()
    fresh()
    W.update.check_crash = true
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    eq(lastShown().text, "Couldn't reach GitHub. Check Wi-Fi and try again.")
end)

test("a failed install explains why and offers no restart", function()
    fresh({ check_result = { { version = "9.9.9" } }, install_result = { nil, "checksum" } })
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    lastShown().ok_callback()
    eq(lastShown().text, "The download didn't check out, so nothing was changed.")
    eq(W.restarted, false)
end)

test("a crashing install is caught and reported", function()
    fresh({ check_result = { { version = "9.9.9" } } })
    W.update.install_crash = true
    local ui = newReader()
    menuItem(menu(ui), "Check for updates (").callback()
    lastShown().ok_callback()
    eq(lastShown().text, "Couldn't write the update to this device.")
end)

test("auto check: skipped when off, when checked less than a day ago, or when offline", function()
    fresh({ online = true, settings = { pageframe = { auto_update_check = false } } })
    newReader().plugin:onReaderReady(); W.flush()
    eq(W.update.checks, 0)
    fresh({ online = true, settings = { pageframe = { last_update_check = os.time() - 3600 } } })
    newReader().plugin:onReaderReady(); W.flush()
    eq(W.update.checks, 0)
    fresh({ online = false })
    newReader().plugin:onReaderReady(); W.flush()
    eq(W.update.checks, 0)
    eq(W.ran_online, nil) -- never turns Wi-Fi on
end)

test("auto check: when due, records the time first, then asks about a newer version", function()
    fresh({ online = true, check_result = { { version = "9.9.9" } } })
    local ui = newReader()
    ui.plugin:onReaderReady()
    assert(W.settings.pageframe.last_update_check, "time saved before the check runs")
    eq(W.update.checks, 0) -- scheduled, not run yet
    W.flush()
    eq(W.update.checks, 1)
    assert(lastShown().text:find("v9.9.9 is ready", 1, true))
    eq(#W.update.installs, 0) -- never installs by itself
end)

test("auto check: up to date or failing stays silent", function()
    fresh({ online = true })
    newReader().plugin:onReaderReady(); W.flush()
    eq(W.update.checks, 1)
    eq(#W.shown, 0)
    fresh({ online = true, check_result = { nil, "network" } })
    newReader().plugin:onReaderReady(); W.flush()
    eq(#W.shown, 0)
end)

test("the automatic check can be turned off in the menu", function()
    fresh()
    local ui = newReader()
    local item = menuItem(menu(ui), "Check for updates automatically")
    eq(item.checked_func(), true)
    item.callback()
    eq(W.settings.pageframe.auto_update_check, false)
end)

H.done()
