-- KOReader user patch (test only): opens a made-up demo book, fakes a Goodreads
-- session with made-up data (nothing goes online), walks Blossom Reads' popups
-- and saves screenshots, then quits. Active only when BLOSSOMREADS_SHOTS is set;
-- installed by tools/screenshots_reads.sh into a throwaway demo home.
local out = os.getenv("BLOSSOMREADS_SHOTS")
if not out then return end
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")

local GR = "https://www.goodreads.com"
local function row(i, title, author, stars)
    return string.format([[<tr class="bookalike review"><td><a title="%s" href="/book/show/%d-x">%s</a></td>
      <td class="field author"><div class="value"><a href="/a">%s</a></div></td>
      <td><div class="stars" data-rating="%d"></div></td></tr>]], title, i, title, author, stars)
end
local ROUTES = {
    [GR .. "/review/list"] = [[<meta name="csrf-token" content="demo" /><a href="/user/show/1-demo">me</a>
        <script>new ShelfChooser("x", 0, ["currently-reading","to-read","read","cozy-autumn"], {})</script>
        <a href="?shelf=currently-reading">Currently Reading (2)</a><a href="?shelf=to-read">Want to Read (31)</a>
        <a href="?shelf=read">Read (58)</a><a href="?shelf=cozy-autumn">cozy-autumn (7)</a>]],
    [GR .. "/readingchallenges/goals/data"] = [[{"readingGoal":24,"readingProgress":9,"daysRemaining":90}]],
    [GR .. "/review/list?shelf=to-read&per_page=30&page=1&view=table"] = table.concat({
        row(11, "The Lantern Keeper's Daughter", "Rosalind Fair", 0), row(12, "Tea for Two Ghosts", "Maple Quinn", 0),
        row(13, "Ribbons in the Rain", "Lottie Brooks", 0), row(14, "The Cottage at Bramble End", "Edie Fox", 0),
        row(15, "Small Kindnesses", "Nora Pike", 0), row(16, "Sea Glass Summer", "Bea Winslow", 0),
    }),
    [GR .. "/book/auto_complete?format=json&q=honey"] =
        [[ [{"bookId":21,"bookTitleBare":"Paper Hearts & Honey","author":{"name":"Ivy Lane"}},
            {"bookId":22,"bookTitleBare":"Honey in the Hollow","author":{"name":"Ada Penrose"}},
            {"bookId":23,"bookTitleBare":"The Honeybee Letters","author":{"name":"Juniper Hale"}}] ]],
}
local function transport(req)
    local body = ROUTES[req.url]
    if body then return 200, {}, body end
    if req.method == "POST" then return 200, {}, "{}" end
    return 404, {}, ""
end

local function top()
    return UIManager._window_stack[#UIManager._window_stack].widget
end

UIManager:scheduleIn(3, function()
    local FileManager = require("apps/filemanager/filemanager")
    local home = G_reader_settings:readSetting("home_dir")
    local file = home .. "/a-garden-of-small-hours.epub"
    require("apps/reader/readerui"):showReader(file)
    UIManager:scheduleIn(4, function()
        local reader = require("apps/reader/readerui").instance
        local p = reader and reader.blossomreads
        if not p then logger.err("BRSHOT plugin missing"); UIManager:quit(); return end
        p.transport = transport
        require("blossomreads_login").saveSession("demo=1", "1", "valid")
        p:linkBook(file, { gid = "1", title = "A Garden of Small Hours", author = "Mina Hart" })
        local books = require("blossomreads_store").open("books")
        local e = books:get(file)
        e.pushed_shelf, e.rating, e.synced_at = "currently-reading", 5, os.time()
        books:set(file, e)
        books:flush()
        local steps = {
            { "r1-home", function() p:showHome() end },
            { "r2-this-book", function() UIManager:close(top()); p:showBook() end },
            { "r3-shelf", function() UIManager:close(top()); require("blossomreads_list").shelf(p, "to-read") end },
            { "r4-search", function() UIManager:close(top()); require("blossomreads_list").search(p, "honey") end },
            { "r5-sync", function() UIManager:close(top()); p:runSync{} end },
            { "r6-menu-card", function() UIManager:close(top()); p:card(p.summaryText{ books = 2, goal = { value = 24 } }, 30) end },
        }
        local i = 0
        local function step()
            i = i + 1
            local s = steps[i]
            if not s then UIManager:quit(); return end
            local ok, err = pcall(s[2])
            if not ok then logger.err("BRSHOT step failed", s[1], err) end
            UIManager:scheduleIn(2, function()
                UIManager:forceRePaint()
                Screen:shot(out .. "/" .. s[1] .. ".png")
                logger.info("BRSHOT saved", s[1])
                step()
            end)
        end
        UIManager:scheduleIn(1, step)
    end)
end)
