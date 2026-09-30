-- KOReader user patch (test only): opens Blossom, walks every page and saves screenshots, then quits.
-- Active only when BLOSSOM_SHOTS is set; installed by tools/screenshots.sh into a throwaway demo home.
local out = os.getenv("BLOSSOM_SHOTS")
if not out then return end
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")

local steps = {
    { "1-overview", function(v) v:goToPage(1) end },
    { "2-week", function(v) v:goToPage(2) end },
    { "3-books", function(v) v:goToPage(3) end },
    { "4-month-covers", function(v) v.year, v.month = 2026, 9; v:goToPage(4) end },
    { "5-month-calendar", function(v) v.month_mode = "calendar"; v:refresh() end },
    { "6-year", function(v) v:goToPage(5) end },
    { "7-detail", function(v) v:openBook(9) end },
    { "8-day", function(v)
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        v:openDay(os.date("%Y-%m-%d"))
    end },
    { "9-garden-books", function(v)
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        v:openMore("time")
    end },
    { "10-garden-highlights", function(v)
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        v:openMore("highlights")
    end },
    { "11-garden-bookmarks", function(v)
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        v:openMore("bookmarks")
    end },
    { "12-window", function(v)
        -- Close everything Blossom showed, then reopen as a floating window over the bookshelf.
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
        UIManager:close(v)
        local s = G_reader_settings:readSetting("blossom") or {}
        s.open_as = "window"
        G_reader_settings:saveSetting("blossom", s)
        local host = require("apps/filemanager/filemanager").instance or require("apps/reader/readerui").instance
        host.blossom:show()
    end },
}

UIManager:scheduleIn(4, function()
    local fm = require("apps/filemanager/filemanager").instance or require("apps/reader/readerui").instance
    local util = require("util")
    local ok, err = pcall(function() fm.blossom:show() end)
    if not ok then logger.err("BLOSSOMSHOT show failed", err) end
    local view
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.goToPage then view = w; break end
    end
    logger.info("BLOSSOMSHOT md5 check", util.partialMD5(require("readhistory").hist[1].file))
    local i = 0
    local function step()
        i = i + 1
        local s = steps[i]
        if not s then UIManager:quit(); return end
        local ok2, err2 = pcall(s[2], view)
        if not ok2 then logger.err("BLOSSOMSHOT step failed", s[1], err2) end
        UIManager:scheduleIn(2, function()
            UIManager:forceRePaint()
            Screen:shot(out .. "/" .. s[1] .. ".png")
            logger.info("BLOSSOMSHOT saved", s[1])
            step()
        end)
    end
    UIManager:scheduleIn(2, step)
end)
