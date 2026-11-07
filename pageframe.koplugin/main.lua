--[[--
Page Frame: draws a decorative frame over every reader page.

The frame image is turned into a greyscale ink mask (BB8) once per size and drawn with
colorblitFrom, the same path KOReader uses for text glyphs. So it is safe on greyscale
(BB8) Kindle screens, colour screens and night mode alike: no RGB32 image ever touches the
screen buffer.

In reflowable books the plugin can also:
  * set the book's margins so the text sits in the largest rectangle that touches none of
    the drawing (the book's own margins are saved and put back when the frame goes away);
  * set a matching font (Cormorant Garamond Italic by default, shipped in fonts/) through
    extra CSS that only exists while a frame is on. The book's font setting is never changed.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Core = require("pageframe_core")

local Screen = Device.screen
local rshift = require("bit").rshift

local SETTINGS_KEY = "pageframe"
local DOC_KEY = "pageframe_margins"
local NONE = "none"
local CELL = 8 -- grid cell size, in pixels, for finding the text area
local UPDATE_EVERY = 24 * 3600 -- automatic update check: at most once a day

-- No frame image ships with the plugin: frames come from koreader/frames/.
-- (Entries here would be { id = "builtin:x", name = ..., file = "frames/x.png" }.)
local BUILTINS = {}

local DARKNESS_NAMES = { soft = _("Soft"), normal = _("Normal"), bold = _("Bold") }

-- Fonts are registered with crengine once per KOReader session.
local fonts_registered = false

local PageFrame = WidgetContainer:extend{
    name = "pageframe",
    is_doc_only = true,
}

-- Settings ----------------------------------------------------------------------

local function readSettings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    -- 1.0.0 shipped a built-in frame; that id no longer exists, so fall back to the default.
    if type(s.frame) == "string" and s.frame:match("^builtin:") then s.frame = nil end
    if not Core.DARKNESS[s.darkness or ""] then s.darkness = "soft" end
    if s.fit_text == nil then s.fit_text = true end
    if s.font == nil then s.font = Core.DEFAULT_FONT end
    if s.italic == nil then s.italic = true end
    if s.crisp == nil then s.crisp = true end
    if s.auto_update_check == nil then s.auto_update_check = true end
    return s
end

function PageFrame:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function PageFrame:customDir()
    return DataStorage:getDataDir() .. "/frames"
end

function PageFrame:refreshFrames()
    local builtins = {}
    for i, b in ipairs(BUILTINS) do
        builtins[i] = { id = b.id, name = b.name, path = self.path .. "/" .. b.file,
                        layout = b.layout, insets = b.insets }
    end
    self.frames = Core.listFrames(builtins, self:customDir(), lfs)
end

--- The frame being shown, or nil. With no saved choice, that's the first frame in the list.
function PageFrame:currentFrame()
    local id = self.settings.frame
    if id == NONE then return nil end
    if id == nil then return self.frames[1] end
    return Core.findFrame(self.frames, id)
end

-- Ink mask ---------------------------------------------------------------------

--- Turn a decoded image into a BB8 ink mask plus a coarse grid of drawn cells.
-- @tparam BlitBuffer src decoded frame image
-- @number k darkness multiplier
-- @tparam[opt] table opts crisp (bool): sharpen and add contrast; cell (int): grid cell size
-- @treturn BlitBuffer mask, table grid (index y * gw + x -> 1), int gw, int gh
function PageFrame._buildMask(src, k, opts)
    opts = opts or {}
    local cell = opts.cell or CELL
    local crisp = opts.crisp and Core.crisp
    local w, h = src:getWidth(), src:getHeight()
    local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local gw, gh = math.ceil(w / cell), math.ceil(h / cell)
    local grid = {}
    local floor_ink, solid, kk = Core.INK_FLOOR, Core.INK_SOLID, k / 255
    local bb_type = src:getType()
    local data = ffi.cast("uint8_t *", src.data)
    local stride = tonumber(src.stride)
    local unrotated = src:getRotation() == 0

    -- Pass 1: raw ink for every pixel.
    local raw = ffi.new("uint8_t[?]", w * h)
    local function put(i, gray, alpha)
        local ink = (255 - gray) * alpha * kk
        raw[i] = ink > 255 and 255 or ink
    end
    if unrotated and bb_type == Blitbuffer.TYPE_BBRGB32 then
        for y = 0, h - 1 do
            local row, base = data + y * stride, y * w
            for x = 0, w - 1 do
                local p = row + x * 4
                put(base + x, rshift(4898 * p[0] + 9618 * p[1] + 1869 * p[2], 14), p[3])
            end
        end
    elseif unrotated and bb_type == Blitbuffer.TYPE_BB8A then
        for y = 0, h - 1 do
            local row, base = data + y * stride, y * w
            for x = 0, w - 1 do
                put(base + x, row[x * 2], row[x * 2 + 1])
            end
        end
    elseif unrotated and bb_type == Blitbuffer.TYPE_BB8 then
        for y = 0, h - 1 do
            local row, base = data + y * stride, y * w
            for x = 0, w - 1 do
                put(base + x, row[x], 255)
            end
        end
    else
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local c = src:getPixel(x, y):getColor8A()
                put(y * w + x, c.a, c.alpha)
            end
        end
    end

    -- Pass 2: crisp lines (optional), drop paper haze, record drawn cells.
    local dst = ffi.cast("uint8_t *", mask.data)
    local dst_stride = tonumber(mask.stride)
    for y = 0, h - 1 do
        local up, down = (y > 0 and y - 1 or y) * w, (y < h - 1 and y + 1 or y) * w
        local mid = y * w
        local cy = math.floor(y / cell) * gw
        for x = 0, w - 1 do
            local ink = raw[mid + x]
            if crisp then
                local l, r = x > 0 and x - 1 or x, x < w - 1 and x + 1 or x
                local sum = raw[up + l] + raw[up + x] + raw[up + r]
                          + raw[mid + l] + ink + raw[mid + r]
                          + raw[down + l] + raw[down + x] + raw[down + r]
                ink = crisp(ink, sum / 9)
            end
            if ink < floor_ink then
                ink = 0
            else
                ink = math.floor(ink)
                if ink >= solid then grid[cy + math.floor(x / cell)] = 1 end
            end
            dst[y * dst_stride + x] = ink
        end
    end
    return mask, grid, gw, gh
end

--- Clear pixel boxes { x, y, w, h } in a BB8 mask.
local function eraseBoxes(mask, boxes)
    local dst = ffi.cast("uint8_t *", mask.data)
    local stride = tonumber(mask.stride)
    for _, b in ipairs(boxes) do
        for y = b[2], b[2] + b[4] - 1 do
            ffi.fill(dst + y * stride + b[1], b[3], 0)
        end
    end
end

-- The view module: paints the frame on every page ------------------------------

local FrameLayer = {}
FrameLayer.__index = FrameLayer

function FrameLayer:new(plugin)
    return setmetatable({ plugin = plugin, cache = nil, failed_key = nil }, self)
end

--- Size of the area the frame covers: the screen, minus the status bar when it takes its own room.
function FrameLayer:area()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local view = self.plugin.ui.view
    local footer = view and view.footer
    if view and view.footer_visible and footer
            and not (footer.settings and footer.settings.reclaim_height) then
        h = h - footer:getHeight()
    end
    return w, h
end

function FrameLayer:free()
    if self.cache and self.cache.mask then self.cache.mask:free() end
    self.cache = nil
end

--- The prepared frame ({ mask, w, h, insets }) for the current settings and size, or nil.
function FrameLayer:prepare()
    local plugin = self.plugin
    local frame = plugin:currentFrame()
    if not frame then
        self:free()
        return nil
    end
    local w, h = self:area()
    local key = table.concat({ frame.path, w, h, plugin.settings.darkness, tostring(plugin.settings.crisp) }, "|")
    if self.cache and self.cache.key == key then return self.cache end
    if self.failed_key == key then return nil end

    self:free()
    local started = os.clock()
    local ok, result = pcall(function()
        local src = RenderImage:renderImageFile(frame.path, false, w, h)
        if not src then error("could not decode image") end
        if src:getWidth() ~= w or src:getHeight() ~= h then
            src = RenderImage:scaleBlitBuffer(src, w, h)
        end
        local mask, grid, gw, gh = PageFrame._buildMask(src, Core.DARKNESS[plugin.settings.darkness],
            { crisp = plugin.settings.crisp })
        src:free()
        local insets, specks = Core.textRect(grid, gw, gh, {
            cell = CELL, area_w = w, area_h = h, insets = frame.insets,
            min_w = frame.layout == "wide" and math.floor(gw * 0.72) or 0,
        })
        eraseBoxes(mask, Core.specksInside(specks, gw, insets, w, h, CELL))
        return { key = key, mask = mask, w = w, h = h, insets = insets }
    end)
    if not ok or not result then
        logger.warn("PageFrame: cannot prepare frame", frame.path, result)
        self.failed_key = key
        Notification:notify(T(_("Couldn't open frame image %1"), frame.name))
        return nil
    end
    logger.info(string.format("PageFrame: prepared %s at %dx%d in %.2f s", frame.name, w, h, os.clock() - started))
    self.failed_key = nil
    self.cache = result
    plugin:onFramePrepared()
    return result
end

function FrameLayer:paintTo(bb, x, y)
    local ok, frame = pcall(self.prepare, self)
    if ok and frame then
        bb:colorblitFrom(frame.mask, x, y, 0, 0, frame.w, frame.h, Blitbuffer.COLOR_BLACK)
    elseif not ok then
        logger.warn("PageFrame: paint failed", frame)
    end
end

-- Plugin ----------------------------------------------------------------------

function PageFrame:init()
    self.settings = readSettings()
    self:refreshFrames()
    self.is_reflowable = self.ui.rolling ~= nil
    if self.is_reflowable then
        self:registerFonts()
        self:hookStyleSheet()
    end
    self.layer = FrameLayer:new(self)
    self.ui.view:registerViewModule("pageframe", self.layer)
    Dispatcher:registerAction("pageframe_toggle", {
        category = "none", event = "TogglePageFrame", title = _("Toggle page frame"), reader = true,
    })
    self.ui.menu:registerToMainMenu(self)
    if self.path then
        -- Remove the .old / .new folders an earlier update left behind.
        local ok, err = pcall(function() require("pageframe_update").cleanup(self.path) end)
        if not ok then logger.warn("PageFrame: update cleanup failed", err) end
    end
end

function PageFrame:registerFonts()
    if fonts_registered then return end
    fonts_registered = true
    local dir = self.path .. "/fonts"
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local ok, cre = pcall(require, "libs/libkoreader-cre")
    if not ok then
        logger.warn("PageFrame: crengine not available, fonts not registered")
        return
    end
    for file in lfs.dir(dir) do
        -- Skip hidden files, such as the "._" copies macOS leaves on FAT drives.
        if file:sub(1, 1) ~= "." and file:lower():match("%.[ot]tf$") then
            local done, err = pcall(cre.registerFont, dir .. "/" .. file)
            if not done then logger.warn("PageFrame: cannot register font", file, err) end
        end
    end
end

-- Adds the frame's font CSS to the style tweaks' CSS, for this book only.
function PageFrame:hookStyleSheet()
    local styletweak = self.ui.styletweak
    if not styletweak then return end
    local original = styletweak.getCssText
    local plugin = self
    styletweak.getCssText = function(this)
        local css = original(this)
        local extra = Core.fontCss(plugin.settings, plugin:currentFrame() ~= nil)
        if extra == "" then return css end
        if css and css ~= "" then return css .. "\n" .. extra end
        return extra
    end
end

function PageFrame:onReaderReady()
    self.ready = true
    self:refit()
    self:autoUpdateCheck()
end

function PageFrame:onCloseDocument()
    self.ready = false
    self.layer:free()
end

-- Called by the layer whenever a new mask is built (new frame, size or darkness).
function PageFrame:onFramePrepared()
    if not self.ready or self.refit_scheduled then return end
    self.refit_scheduled = true
    UIManager:nextTick(function()
        self.refit_scheduled = false
        if self.ready then self:refit() end
    end)
end

-- Margins ---------------------------------------------------------------------

function PageFrame:currentMargins()
    local c = self.ui.document.configurable
    return { c.h_page_margins[1], c.t_page_margin, c.h_page_margins[2], c.b_page_margin }
end

function PageFrame:setMargins(m)
    local c = self.ui.document.configurable
    c.h_page_margins = { m[1], m[3] }
    c.t_page_margin = m[2]
    c.b_page_margin = m[4]
    if self.ui.typeset then
        self.ui.typeset.unscaled_margins = { m[1], m[2], m[3], m[4] }
    end
    self.ui:handleEvent(Event:new("SetPageMargins", { m[1], m[2], m[3], m[4] }))
end

--- Unscaled margins that keep the text clear of the frame, or nil when not wanted/possible.
function PageFrame:wantedMargins()
    if not self.is_reflowable or not self.settings.fit_text then return nil end
    local frame = self.layer:prepare()
    if not frame or not frame.insets then return nil end
    return Core.marginsFor(frame.insets, Screen:scaleBySize(1000) / 1000)
end

function PageFrame:refit()
    local want = self:wantedMargins()
    if not want then return self:restoreMargins() end
    local state = self.ui.doc_settings:readSetting(DOC_KEY)
    if state and Core.marginsEqual(state.applied, want) then return end
    state = state or { saved = self:currentMargins() }
    state.applied = want
    self.ui.doc_settings:saveSetting(DOC_KEY, state)
    self:setMargins(want)
end

function PageFrame:restoreMargins()
    local state = self.ui.doc_settings:readSetting(DOC_KEY)
    if not state then return end
    self.ui.doc_settings:delSetting(DOC_KEY)
    -- If the margins were changed by hand since, those win.
    if state.saved and Core.marginsEqual(self:currentMargins(), state.applied) then
        self:setMargins(state.saved)
    end
end

-- Changes ---------------------------------------------------------------------

--- Re-apply everything after a setting change.
-- @bool css whether the font CSS may have changed (needs a re-render)
function PageFrame:applyChange(css)
    self:saveSettings()
    if css and self.is_reflowable then
        self.ui:handleEvent(Event:new("ApplyStyleSheet"))
    end
    if self.ready then self:refit() end
    UIManager:setDirty(self.ui.dialog, "full")
end

function PageFrame:setFrame(id)
    local shown = self:currentFrame()
    if shown and id == NONE then
        self.settings.last_frame = shown.id
    end
    self.settings.frame = id
    self:applyChange(true)
end

function PageFrame:onTogglePageFrame()
    if self:currentFrame() then
        self:setFrame(NONE)
    else
        local id = self.settings.last_frame
        if not Core.findFrame(self.frames, id) then id = self.frames[1] and self.frames[1].id end
        if id then self:setFrame(id) end
    end
    return true
end

-- Updates -------------------------------------------------------------------

local UPDATE_ERRORS = {
    network = _("Couldn't reach GitHub. Check Wi-Fi and try again."),
    checksum = _("The download didn't check out, so nothing was changed."),
    bad_zip = _("The update file looked wrong, so nothing was changed."),
    incomplete = _("The update file looked wrong, so nothing was changed."),
    write = _("Couldn't write the update to this device."),
    swap = _("Couldn't replace the plugin folder. Your current version is still in place."),
}

-- The version from _meta.lua (KOReader copies its fields onto the plugin).
function PageFrame:pluginVersion()
    if type(self.version) == "string" then return self.version end
    local ok, meta = pcall(dofile, (self.path or ".") .. "/_meta.lua")
    return ok and type(meta) == "table" and meta.version or "0.0.0"
end

local function message(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = text, timeout = timeout }
    UIManager:show(msg)
    return msg
end

local function runWhenOnline(fn)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(fn)
    else
        fn()
    end
end

local function isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr and NetworkMgr.isOnline and NetworkMgr:isOnline() or false
end

-- Looks for a newer release in a background child, then calls on_done(info, err).
function PageFrame:findUpdate(on_done)
    local version = self:pluginVersion()
    require("pageframe_background").run(function()
        return require("pageframe_update").check(version)
    end, function(ok, info, err)
        if not ok then
            logger.warn("PageFrame: update check crashed", info)
            info, err = nil, "network"
        end
        on_done(info, err)
    end)
end

--- Once a day, when Wi-Fi is already on: if there's a newer version, ask (never installs by itself).
function PageFrame:autoUpdateCheck()
    local s = self.settings
    if not s.auto_update_check then return end
    if os.time() - (s.last_update_check or 0) < UPDATE_EVERY then return end
    if not isOnline() then return end
    s.last_update_check = os.time() -- before checking, so a failing network doesn't retry every book
    self:saveSettings()
    UIManager:scheduleIn(4, function()
        self:findUpdate(function(info, err)
            if info then
                self:offerUpdate(info)
            elseif err then
                logger.info("PageFrame: automatic update check failed:", err)
            end
        end)
    end)
end

function PageFrame:checkForUpdates()
    runWhenOnline(function()
        local msg = message(_("Looking for updates…"))
        self:findUpdate(function(info, err)
            UIManager:close(msg)
            self.settings.last_update_check = os.time()
            self:saveSettings()
            if info then
                self:offerUpdate(info)
            elseif err then
                message(UPDATE_ERRORS[err] or UPDATE_ERRORS.network, 5)
            else
                message(T(_("You have the latest Page Frame (v%1)."), self:pluginVersion()), 4)
            end
        end)
    end)
end

function PageFrame:offerUpdate(info)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Page Frame v%1 is ready.\nYou have v%2. Update now?"), info.version, self:pluginVersion()),
        ok_text = _("Update"),
        cancel_text = _("Later"),
        ok_callback = function() self:installUpdate(info) end,
    })
end

function PageFrame:installUpdate(info)
    if not self.path then return end
    local msg = message(T(_("Updating to v%1…"), info.version))
    UIManager:forceRePaint()
    local ok, version, err = pcall(require("pageframe_update").install, info, self.path)
    UIManager:close(msg)
    if not ok then
        logger.warn("PageFrame: update crashed", version)
        version, err = nil, "write"
    end
    if not version then
        logger.warn("PageFrame: update failed", err)
        message(UPDATE_ERRORS[err] or UPDATE_ERRORS.write, 6)
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Updated to v%1.\nRestart KOReader now to use it?"), version),
        ok_text = _("Restart"),
        cancel_text = _("Later"),
        ok_callback = function() UIManager:restartKOReader() end,
    })
end

-- Menu ------------------------------------------------------------------------

function PageFrame:addToMainMenu(menu_items)
    menu_items.pageframe = {
        text = _("Page frame"),
        sorting_hint = "typeset",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

local function reflowableOnly(item, plugin)
    item.enabled_func = function() return plugin.is_reflowable end
    return item
end

function PageFrame:menuItems()
    self:refreshFrames()
    local items = {
        {
            text = _("None"),
            radio = true,
            checked_func = function() return self:currentFrame() == nil end,
            callback = function() self:setFrame(NONE) end,
        },
    }
    for _, frame in ipairs(self.frames) do
        items[#items + 1] = {
            text = frame.name,
            radio = true,
            checked_func = function()
                local shown = self:currentFrame()
                return shown ~= nil and shown.id == frame.id
            end,
            callback = function() self:setFrame(frame.id) end,
        }
    end
    if #self.frames == 0 then
        items[#items + 1] = {
            text = _("Add frame images to koreader/frames/"),
            help_text = _([[Put PNG, JPG or WebP frame images in the "frames" folder next to KOReader's "plugins" folder, then open this menu again.]]),
            enabled_func = function() return false end,
        }
    end
    items[#items].separator = true

    local darkness = {}
    for _, key in ipairs(Core.DARKNESS_ORDER) do
        darkness[#darkness + 1] = {
            text = DARKNESS_NAMES[key],
            radio = true,
            checked_func = function() return self.settings.darkness == key end,
            callback = function()
                self.settings.darkness = key
                self:applyChange(false)
            end,
        }
    end
    items[#items + 1] = {
        text_func = function() return T(_("Darkness: %1"), DARKNESS_NAMES[self.settings.darkness]) end,
        sub_item_table = darkness,
    }
    items[#items + 1] = {
        text = _("Crisp lines"),
        help_text = _([[Sharpens the frame's linework and deepens its shadows, so soft artwork looks crisp on e-ink. Turn it off for frames that are already clean line art.]]),
        checked_func = function() return self.settings.crisp end,
        callback = function()
            self.settings.crisp = not self.settings.crisp
            self:applyChange(false)
        end,
    }
    items[#items + 1] = reflowableOnly({
        text = _("Keep text inside the frame"),
        help_text = _([[Sets this book's margins so the text never touches the frame's drawing. The book's own margins come back when the frame is turned off. Only for reflowable books (EPUB and similar).]]),
        checked_func = function() return self.is_reflowable and self.settings.fit_text end,
        callback = function()
            self.settings.fit_text = not self.settings.fit_text
            self:applyChange(false)
        end,
    }, self)
    items[#items + 1] = reflowableOnly({
        text_func = function()
            local font = self.settings.font
            return T(_("Font with the frame: %1"), font == Core.KEEP_FONT and _("book's own") or font)
        end,
        sub_item_table_func = function() return self:fontItems() end,
    }, self)
    items[#items + 1] = reflowableOnly({
        text = _("Italic text"),
        help_text = _([[Sets the text in italics while a frame is shown. Emphasised words turn upright, so they still stand out.]]),
        checked_func = function() return self.is_reflowable and self.settings.italic end,
        callback = function()
            self.settings.italic = not self.settings.italic
            self:applyChange(true)
        end,
    }, self)
    items[#items].separator = true
    items[#items + 1] = {
        text_func = function() return T(_("Check for updates (v%1)"), self:pluginVersion()) end,
        keep_menu_open = true,
        callback = function() self:checkForUpdates() end,
    }
    items[#items + 1] = {
        text = _("Check for updates automatically"),
        help_text = _([[Once a day, when a book opens and Wi-Fi is already on, looks for a newer Page Frame and asks before installing it.]]),
        checked_func = function() return self.settings.auto_update_check end,
        callback = function()
            self.settings.auto_update_check = not self.settings.auto_update_check
            self:saveSettings()
        end,
    }
    return items
end

function PageFrame:fontItems()
    local function choose(font)
        return {
            radio = true,
            checked_func = function() return self.settings.font == font end,
            callback = function()
                self.settings.font = font
                self:applyChange(true)
            end,
        }
    end
    local keep = choose(Core.KEEP_FONT)
    keep.text = _("Keep the book's font")
    local included = choose(Core.DEFAULT_FONT)
    included.text = T(_("%1 (included)"), Core.DEFAULT_FONT)
    included.separator = true
    local items = { keep, included }
    local ok, cre = pcall(require, "libs/libkoreader-cre")
    local faces = ok and cre.getFontFaces() or {}
    table.sort(faces)
    for _, face in ipairs(faces) do
        if face ~= Core.DEFAULT_FONT then
            local item = choose(face)
            item.text = face
            items[#items + 1] = item
        end
    end
    return items
end

return PageFrame
