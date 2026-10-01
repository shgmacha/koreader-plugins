-- Blossom Reads: store, secret, http, login, api and identify units (plain LuaJIT).
local H = require("tests.harness")
local test, eq = H.test, H.eq

local function freshDir(name)
    local base = os.tmpname()
    os.remove(base)
    local d = base .. "-" .. name
    os.execute('rm -rf "' .. d .. '"')
    return d
end
local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end

-- KOReader's LuaSettings, including its silent no-op flush when the folder is missing.
local settings_root = freshDir("settings")
os.execute('mkdir -p "' .. settings_root .. '"')
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return settings_root end }
end
package.preload["luasettings"] = function()
    local LS = {}
    LS.__index = LS
    function LS:open(file)
        local ok, stored = pcall(dofile, file)
        return setmetatable({ file = file, data = (ok and stored) or {} }, LS)
    end
    function LS:readSetting(k) return self.data[k] end
    function LS:saveSetting(k, v) self.data[k] = v end
    function LS:flush()
        local f = io.open(self.file, "w")
        if f then
            f:write("return " .. require("blossomreads_store").serialize(self.data))
            f:close()
        end
    end
    return LS
end

local Store = require("blossomreads_store")

test("store: creates settings/blossomreads/ so a fresh install persists (login bug)", function()
    local s = Store.open("session")
    s:set("cookies", "a=1")
    assert(s:flush(), "flush failed")
    assert(exists(settings_root .. "/blossomreads/session.lua"), "file not written")
    eq(Store.open("session"):get("cookies"), "a=1")
end)

test("store: deleted keys stay deleted after reopening", function()
    local s = Store.open("creds")
    s:set("email", "x"); s:set("password", "y"); s:flush()
    s = Store.open("creds")
    s:delete("password"); s:flush()
    eq(Store.open("creds"):get("password"), nil)
    eq(Store.open("creds"):get("email"), "x")
end)

test("store: plain serializer round-trips nested tables (test fallback)", function()
    Store.setDir(freshDir("plain"))
    local s = Store.open("books")
    s:set("/b/Dune.epub", { gid = "1", pushed_pct = 47, title = 'Q"uote' })
    s:flush()
    eq(Store.open("books"):get("/b/Dune.epub"), { gid = "1", pushed_pct = 47, title = 'Q"uote' })
    Store.setDir(nil)
end)

test("store: unchanged file is not rewritten", function()
    local s = Store.open("session")
    eq(s.dirty, nil)
    assert(s:flush())
end)

local Secret = require("blossomreads_secret")
local LIBCRYPTO = "/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib"

test("secret: without libcrypto values stay plain text", function()
    Secret._setLib(nil)
    eq({ Secret.protect("hunter2") }, { "hunter2", false })
    eq(Secret.unprotect("hunter2", false), "hunter2")
end)

if exists(LIBCRYPTO) then
    Secret._setLib(require("ffi").load(LIBCRYPTO))

    test("secret: AES round trip, ciphertext differs from plain text", function()
        local blob, enc = Secret.protect("session=abc; ubid=1")
        eq(enc, true)
        assert(not blob:find("abc"), "plain text leaked")
        eq(Secret.unprotect(blob, true), "session=abc; ubid=1")
    end)

    test("secret: a key written by another process is picked up (no stale empty cache)", function()
        local blob = Secret.protect("x")
        Secret._setLib(require("ffi").load(LIBCRYPTO)) -- drop the cached key, as a fresh process
        eq(Secret.unprotect(blob, true), "x")
    end)

    test("secret: garbage or wrong-key blobs give nil, not an error", function()
        eq(Secret.unprotect("zz", true), nil)
        eq(Secret.unprotect(string.rep("ab", 40), true), nil)
    end)
else
    print("skip secret AES tests: " .. LIBCRYPTO .. " not found")
end

local Http = require("blossomreads_http")
Http.sleep = function() end -- no real pauses between retries in tests

-- Scripted transport: routes[url] = { status, headers, body } (or a list, consumed in order).
local function fakeTransport(routes, log)
    return function(req)
        if log then log[#log + 1] = req end
        local r = routes[req.url]
        if type(r) == "table" and (type(r[1]) == "table" or r[1] == "down") then r = table.remove(r, 1) end
        if not r then return 404, {}, "" end
        if r == "down" then return nil end
        return r[1], r[2] or {}, r[3] or ""
    end
end
_G.fakeTransport = fakeTransport

test("http: Set-Cookie merge splits folded headers and keeps Expires dates whole", function()
    local jar = Http.mergeSetCookie("old=1; keep=2",
        "a=1; Expires=Thu, 01 Jan 2027 00:00:00 GMT; Path=/, b=x=y==; Domain=.goodreads.com, old=3")
    eq(jar, "old=3; keep=2; a=1; b=x=y==")
end)

test("http: cookie deletions remove the cookie (the old plugin kept them)", function()
    eq(Http.mergeSetCookie("a=1; b=2; c=3", "a=; Path=/, b=gone; Max-Age=0, c=x; Expires=Thu, 01 Jan 1970 00:00:00 GMT"), "")
end)

test("http: jwt_token is never kept", function()
    eq(Http.mergeSetCookie("s=1", "jwt_token=abc; Path=/"), "s=1")
end)

test("http: follows redirects, carries cookies, POST becomes GET on 302", function()
    local log = {}
    local c = Http.new{ transport = fakeTransport({
        ["https://www.goodreads.com/a"] = { 302, { Location = "/b", ["Set-Cookie"] = "s=1; Path=/" } },
        ["https://www.goodreads.com/b"] = { 200, {}, "done" },
    }, log) }
    local r = c:post("https://www.goodreads.com/a", { x = "1 2" })
    eq({ r.status, r.body, r.err, r.url }, { 200, "done", nil, "https://www.goodreads.com/b" })
    eq(log[1].body, "x=1%202")
    eq({ log[2].method, log[2].headers.Cookie }, { "GET", "s=1" })
end)

test("http: only a real sign-in page means 'signin'; firewall pages are 'blocked'", function()
    eq(Http.classify(200, {}, "https://www.goodreads.com/user/sign_in"), "signin")
    eq(Http.classify(200, {}, "https://www.goodreads.com/ap/signin?x"), "signin")
    eq(Http.classify(401, {}, "u"), "signin")
    eq(Http.classify(403, {}, "u"), "blocked")
    eq(Http.classify(202, {}, "u"), "blocked")
    eq(Http.classify(200, { ["x-amzn-waf-action"] = "challenge" }, "u"), "blocked")
    eq(Http.classify(200, {}, "https://www.goodreads.com/book/show/1"), nil)
    eq(Http.classify(nil), "network")
    eq(Http.classify(500, {}, "u"), "server")
end)

test("http: signin_ok lets the login flow read sign-in pages", function()
    local c = Http.new{ transport = fakeTransport({ ["https://www.goodreads.com/user/sign_in"] = { 200, {}, "<form>" } }) }
    eq(c:get("https://www.goodreads.com/user/sign_in").err, "signin")
    eq(c:get("https://www.goodreads.com/user/sign_in", { signin_ok = true }).err, nil)
end)

test("http: network failure is 'network'", function()
    local c = Http.new{ transport = fakeTransport({ ["https://x/"] = "down" }) }
    eq(c:get("https://x/").err, "network")
end)

test("http: absolute URLs", function()
    eq(Http.absolute("https://a.com/x/y?q", "/z"), "https://a.com/z")
    eq(Http.absolute("https://a.com/x/y", "z"), "https://a.com/x/z")
    eq(Http.absolute("https://a.com/x", "//b.com/p"), "https://b.com/p")
end)

test("http: JSON fallback decoder", function()
    eq(Http.json([[{"a":[1,2.5,-3],"b":"\u00e9\n","c":true,"d":null,"e":{}}]]),
        { a = { 1, 2.5, -3 }, b = "é\n", c = true, e = {} })
    eq(Http.json("not json"), nil)
end)

local Login = require("blossomreads_login")
local GR = "https://www.goodreads.com"
local AP = "https://www.amazon.com/ap/signin"

local function page(form) return "<html><body>" .. form .. "</body></html>" end
local SIGNIN_LANDING = page([[<a href="https://www.goodreads.com/ap/signin?openid.return_to=x&amp;identityProvider=apple">Apple</a>
<a href="https://www.goodreads.com/ap/signin?openid.return_to=x&amp;language=en">Email</a>]])
local AP_FORM = page([[<form name="signIn" method="post" action="https://www.amazon.com/ap/signin">
<input type="hidden" name="appActionToken" value="tok&amp;1"><input type="email" name="email">
<input type="password" name="password"><input type="checkbox" name="rememberMe" value="true"></form>]])
local REVIEW_LIST = page([[<a href="/user/show/42-reader">me</a>]])
local function routes(extra)
    local r = {
        [GR .. "/user/sign_in"] = { 200, {}, SIGNIN_LANDING },
        [GR .. "/ap/signin?openid.return_to=x&language=en"] = { 200, {}, AP_FORM },
        [GR .. "/review/list"] = { 200, {}, REVIEW_LIST },
    }
    for k, v in pairs(extra) do r[k] = v end
    return r
end

Store.setDir(freshDir("login"))

test("login: email + password → signed in, session saved and encrypted", function()
    local log = {}
    local res = Login.start("me@x.com", "pw", { transport = fakeTransport(routes{
        [AP] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s1; Path=/" } },
        [GR .. "/"] = { 200, {}, "home" },
    }, log) })
    eq(res, { ok = true, user_id = "42" })
    assert(Login.signedIn(), "not signed in")
    eq(Login.session().cookies, "session-id=s1")
    local raw = Store.open("session"):get("cookies")
    assert(not raw:find("s1"), "cookies stored in plain text")
    -- skipped the 'sign in with Apple' link; posted hidden token + credentials + remember me
    local post
    for _, req in ipairs(log) do if req.method == "POST" then post = req end end
    assert(post.body:find("appActionToken=tok%%261"), post.body)
    assert(post.body:find("email=me%%40x.com") and post.body:find("password=pw") and post.body:find("rememberMe=true"), post.body)
    assert(not Login.pending(), "pending state left behind")
end)

test("login: wrong password", function()
    eq(Login.start("me@x.com", "bad", { transport = fakeTransport(routes{
        [AP] = { 200, {}, page("<div>Your password is incorrect</div>") },
    }) }), { err = "credentials" })
end)

test("login: verification code step keeps its state between dialogs", function()
    local t = fakeTransport(routes{
        [AP] = { 200, {}, page([[<h1>Two-Step Verification</h1><form action="/ap/mfa">
            <input type="hidden" name="arb" value="9"><input name="otpCode"></form>]]) },
        ["https://www.amazon.com/ap/mfa"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s2; Path=/" } },
        [GR .. "/"] = { 200, {}, "home" },
    })
    eq(Login.start("me@x.com", "pw", { transport = t }), { need = "otp" })
    assert(Login.pending(), "state lost")
    eq(Login.submitOtp("123456"), { ok = true, user_id = "42" })
end)

test("login: picture puzzle → image URL, answer submitted", function()
    local log = {}
    local t = fakeTransport(routes{
        [AP] = { 200, {}, page([[<img src="https://opfcaptcha.amazon.com/x.jpg"><form action="/ap/cvf">
            <input type="hidden" name="cvf" value="1"><input type="text" name="cvf_captcha_input"></form>]]) },
        ["https://opfcaptcha.amazon.com/x.jpg"] = { 200, {}, "JPEG" },
        ["https://www.amazon.com/ap/cvf"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s2; Path=/" } },
        [GR .. "/"] = { 200, {}, "home" },
    }, log)
    local res = Login.start("me@x.com", "pw", { transport = t })
    eq(res, { need = "captcha", image_url = "https://opfcaptcha.amazon.com/x.jpg" })
    eq(Login.captchaImage(res.image_url), "JPEG")
    eq(Login.submitCaptcha("AB12"), { ok = true, user_id = "42" })
    assert(log[#log - 2].body:find("cvf_captcha_input=AB12"), log[#log - 2].body)
end)

test("login: Amazon's two-page sign-in (email, then password)", function()
    local log = {}
    local t = fakeTransport(routes{
        [GR .. "/ap/signin?openid.return_to=x&language=en"] = { 200, {}, page([[<form action="https://www.amazon.com/ap/signin">
            <input type="hidden" name="a" value="1"><input type="email" name="email"></form>]]) },
        [AP] = { { 200, {}, page([[<form action="https://www.amazon.com/ap/signin/pw">
            <input type="hidden" name="b" value="2"><input type="password" name="password"></form>]]) } },
        [AP .. "/pw"] = { 302, { Location = GR .. "/", ["Set-Cookie"] = "session-id=s2; Path=/" } },
        [GR .. "/"] = { 200, {}, "home" },
    }, log)
    eq(Login.start("me@x.com", "pw", { transport = t }), { ok = true, user_id = "42" })
    local bodies = {}
    for _, req in ipairs(log) do if req.method == "POST" then bodies[#bodies + 1] = req.body end end
    assert(not bodies[1]:find("password"), "password sent on the email page")
    assert(bodies[2]:find("password=pw") and bodies[2]:find("b=2"), bodies[2])
end)

test("login: a check without a picture can't be done here → blocked", function()
    eq(Login.start("me@x.com", "pw", { transport = fakeTransport(routes{
        [AP] = { 200, {}, page("Enter the characters you see below") },
    }) }), { err = "blocked" })
end)

test("login: an answer with no session cookie is not a sign-in", function()
    eq(Login.start("me@x.com", "pw", { transport = fakeTransport(routes{
        [AP] = { 302, { Location = GR .. "/" } }, [GR .. "/"] = { 200, {}, "home" },
    }) }), { err = "credentials" })
end)

test("login: offline", function()
    eq(Login.start("me@x.com", "pw", { transport = fakeTransport({ [GR .. "/user/sign_in"] = "down" }) }), { err = "network" })
end)

test("login: sign out forgets the session; remembered password round trip", function()
    Login.saveCredentials("me@x.com", "pw")
    eq(Login.credentials(), { email = "me@x.com", password = "pw" })
    Login.forgetCredentials()
    eq(Login.credentials(), nil)
    Login.signOut()
    eq(Login.signedIn(), false)
end)

test("login: expired session is not signed in", function()
    Login.saveSession("a=1", "42", "valid")
    Login.markExpired()
    eq({ Login.signedIn(), Login.session().state }, { false, "expired" })
end)

local Api = require("blossomreads_api")
local REVIEW_LIST_PAGE = [[<meta name="csrf-token" content="TOK1" /><a href="/user/show/42-me">me</a>
<script>new ShelfChooser("shelfChooserInput", 0, ["read", "currently-reading", "to-read", "cozy-winter"], {})</script>
<a href="/review/list/42?shelf=read">Read (12)</a><a href="/review/list/42?shelf=to-read">Want to Read (30)</a>
<a href="/review/list/42?shelf=cozy-winter">cozy-winter (3)</a>]]

local function api(routes, log)
    routes["https://www.goodreads.com/review/list"] = routes["https://www.goodreads.com/review/list"] or { 200, {}, REVIEW_LIST_PAGE }
    return Api.new{ cookies = "s=1", transport = fakeTransport(routes, log) }
end

test("api: one CSRF fetch serves several writes; user id picked up", function()
    local log = {}
    local a = api({
        [GR .. "/shelf/add_to_shelf"] = { 200, {}, "{}" },
        [GR .. "/user_status.json"] = { 200, {}, "{}" },
    }, log)
    eq({ a:setShelf("9", "currently-reading") }, { true })
    eq({ a:progress("9", 46.6) }, { 47 })
    eq(a.user_id, "42")
    local gets, posts = 0, {}
    for _, r in ipairs(log) do
        if r.method == "GET" then gets = gets + 1 else posts[#posts + 1] = r end
    end
    eq(gets, 1)
    eq(posts[1].headers["X-CSRF-Token"], "TOK1")
    assert(posts[1].body:find("name=currently%-reading") and posts[1].body:find("book_id=9"), posts[1].body)
    assert(posts[2].body:find("user_status%%5Bpercent%%5D=47"), posts[2].body)
end)

test("api: progress falls back to /user_status when the JSON endpoint is gone; clamps 0..100", function()
    local log = {}
    local a = api({ [GR .. "/user_status"] = { 200, {}, "" } }, log)
    eq({ a:progress("9", 0.2) }, { 1 })
    eq(log[#log].url, GR .. "/user_status")
    eq({ a:progress("9", 140) }, { 100 })
end)

test("api: a write that lands on the sign-in page reports 'signin'", function()
    local a = api({ [GR .. "/shelf/add_to_shelf"] = { 302, { Location = GR .. "/user/sign_in" } },
        [GR .. "/user/sign_in"] = { 200, {}, "form" } })
    eq({ a:setShelf("9", "read") }, { nil, "signin" })
end)

test("api: no CSRF token on the page → unexpected (nothing posted)", function()
    local log = {}
    local a = api({ [GR .. "/review/list"] = { 200, {}, "<html></html>" } }, log)
    eq({ a:rate("9", 5) }, { nil, "unexpected" })
    eq(#log, 1)
end)

test("api: rating 1..5 only", function()
    local a = api({ [GR .. "/review/rate/9?no_lightbox=true&queue=false&stars_click=true&rating=4"] = { 200, {}, "" } })
    eq({ a:rate("9", 4) }, { 4 })
    eq({ a:rate("9", 6) }, { nil, "unexpected" })
end)

test("api: search parses auto_complete JSON", function()
    local a = api({ [GR .. "/book/auto_complete?format=json&q=dune%20herbert"] = { 200, {},
        [[ [{"bookId":44767458,"bookTitleBare":"Dune","author":{"name":"Frank Herbert"},"imageUrl":"https://i/x.jpg","numPages":"658"}] ]] } })
    eq(a:search("dune herbert"), { { gid = "44767458", title = "Dune", author = "Frank Herbert", cover = "https://i/x.jpg", pages = 658 } })
end)

test("api: book details from ld+json", function()
    local a = api({ [GR .. "/book/show/1"] = { 200, {}, [[<script type="application/ld+json">{"name":"Dune &amp; More","author":[{"name":"Frank Herbert"}],"image":"c.jpg","numberOfPages":658,"isbn":"9780441172719","aggregateRating":{"ratingValue":4.27}}</script>]] } })
    eq(a:book("1"), { gid = "1", title = "Dune & More", author = "Frank Herbert", cover = "c.jpg", pages = 658, isbn = "9780441172719", avg_rating = 4.27 })
end)

test("api: shelves with counts, custom shelves marked", function()
    eq(api({}):shelves(), {
        { slug = "read", custom = false, count = 12 },
        { slug = "currently-reading", custom = false },
        { slug = "to-read", custom = false, count = 30 },
        { slug = "cozy-winter", custom = true, count = 3 },
    })
end)

test("api: shelf books rows (custom shelf uses tag=)", function()
    local row = [[<tr id="review_1" class="bookalike review"><td><img id="cover_review_1" src="https://i/c.jpg?a=1&amp;b=2"></td>
      <td><a title="Dune" href="/book/show/44767458-dune">Dune</a></td>
      <td class="field author"><div class="value"><a href="/author/show/1">Herbert, Frank</a></div></td>
      <td><div class="stars" data-rating="4.0"></div></td></tr>]]
    local a = api({ [GR .. "/review/list?tag=cozy-winter&per_page=30&page=1&view=table"] = { 200, {}, row .. '<a rel="next">' } })
    local books, more = a:shelfBooks("cozy-winter", 1)
    eq(books, { { gid = "44767458", title = "Dune", author = "Herbert, Frank", cover = "https://i/c.jpg?a=1&b=2", rating = 4 } })
    eq(more, true)
end)

test("api: reading challenge and goal update with the firewall token", function()
    local log = {}
    local a = api({
        [GR .. "/readingchallenges/goals/data"] = { 200, {}, [[{"readingGoal":24,"readingProgress":9,"daysRemaining":90}]] },
        [GR .. "/readingchallenges/annual"] = { 200, {}, [[<input type="hidden" name="anti-csrftoken-a2z" value="WAF9">]] },
        [GR .. "/readingchallenges/updateGoal?newGoal=30"] = { 200, {}, "{}" },
    }, log)
    eq(a:challenge(), { goal = 24, read = 9, days_left = 90 })
    eq({ a:setGoal(30) }, { 30 })
    eq(log[#log].headers["anti-csrftoken-a2z"], "WAF9")
end)

test("api: no challenge yet → goal 0", function()
    eq(api({ [GR .. "/readingchallenges/goals/data"] = { 200, {}, [[{"booksRead":"[]"}]] } }):challenge(),
        { goal = 0, read = 0 })
end)

local Identify = require("blossomreads_identify")

test("identify: ISBN-10/13 from KOReader identifiers, checksums validated", function()
    eq(Identify.fromProps({ title = "Dune", authors = "Frank Herbert\nX", identifiers = "uuid:123\nurn:isbn:978-0-441-17271-9" }, "/b/Dune.epub"),
        { isbn = "9780441172719", title = "Dune", author = "Frank Herbert" })
    eq(Identify.fromProps({ identifiers = "ISBN: 0441172717" }).isbn, "9780441172719")
    eq(Identify.fromProps({ identifiers = "isbn:9780441172718" }).isbn, nil) -- bad checksum
end)

test("identify: ASIN and file-name fallbacks", function()
    eq(Identify.fromProps({ identifiers = "mobi-asin:B00B7NPRY8" }).asin, "B00B7NPRY8")
    local id = Identify.fromProps({ title = "" }, "/b/Dune - Frank Herbert [9780441172719].epub")
    eq({ id.isbn, id.title, id.author }, { "9780441172719", "Dune", "Frank Herbert" })
end)

test("identify: identifier search links the first hit", function()
    local asked
    local m, how = Identify.match(function(q) asked = q; return { { gid = "1", title = "Dune" } } end, { isbn = "9780441172719", title = "Dune" })
    eq({ m.gid, how, asked }, { "1", "isbn", "9780441172719" })
end)

test("identify: title + author auto-links only an exact, untied match", function()
    local hits = { { gid = "2", title = "Dune Messiah", author = "Frank Herbert" },
        { gid = "1", title = "Dune", author = "Herbert, Frank" } }
    local m, how, ranked = Identify.match(function() return hits end, { title = "Dune", author = "Frank Herbert" })
    eq({ m.gid, how, ranked[1].score }, { "1", "title", 85 })
    -- different author: offered for picking, never auto-linked
    local m2, _, ranked2 = Identify.match(function() return { { gid = "9", title = "Dune", author = "Someone Else" } } end,
        { title = "Dune", author = "Frank Herbert" })
    eq({ m2, #ranked2 }, { nil, 1 })
end)

test("identify: subtitles don't block a match", function()
    eq(Identify.score({ title = "Atomic Habits", author = "James Clear" },
        { title = "Atomic Habits: An Easy & Proven Way to Build Good Habits", author = "James Clear" }), 85)
end)

test("identify: search failure is passed through", function()
    eq({ Identify.match(function() return nil, "network" end, { title = "X" }) }, { nil, nil, nil, "network" })
end)

local Covers = require("blossomreads_covers")

test("covers: downloaded once, then served from disk; tiny or missing images skipped", function()
    Store.setDir(freshDir("covers"))
    local calls = 0
    local jpeg = string.rep("J", 500)
    local t = function(req) calls = calls + 1; if req.url:find("big") then return 200, {}, jpeg end return 200, {}, "x" end
    local p = Covers.get("44767458", "https://i.gr-assets.com/big.jpg", t)
    assert(p and p:find("/covers/44767458%.jpg$"), tostring(p))
    eq(Covers.get("44767458", "https://i.gr-assets.com/big.jpg", t), p)
    eq(calls, 1)
    eq(Covers.get("2", "https://i.gr-assets.com/tiny.jpg", t), nil)
    eq(Covers.get("3", "https://s.gr-assets.com/nophoto/book.png", t), nil)
    eq(Covers.get("4", nil, t), nil)
end)

test("covers: prune keeps only the newest MAX", function()
    Store.setDir(freshDir("prune"))
    Store.ensureDir(Covers.dir())
    local names = {}
    for i = 1, 5 do
        local f = io.open(Covers.dir() .. "/" .. i .. ".jpg", "w"); f:write("x"); f:close()
        names[#names + 1] = i .. ".jpg"
    end
    local fake = {
        dir = function() local i = 0; return function() i = i + 1; return names[i] end end,
        attributes = function(p) return tonumber(p:match("(%d+)%.jpg$")) end,
    }
    local max = Covers.MAX
    Covers.MAX = 3
    Covers.prune(fake)
    Covers.MAX = max
    eq({ exists(Covers.dir() .. "/1.jpg"), exists(Covers.dir() .. "/2.jpg"), exists(Covers.dir() .. "/5.jpg") }, { false, false, true })
    Store.setDir(nil)
end)

test("http: Goodreads hiccups (503, 429, dropped connection) are retried", function()
    local log = {}
    local c = Http.new{ transport = fakeTransport({ ["https://x/a"] = { { 503, {}, "over capacity" }, { 429, {}, "" }, { 200, {}, "ok" } },
        ["https://x/b"] = { "down", { 200, {}, "ok" } } }, log) }
    local r = c:get("https://x/a")
    eq({ r.status, r.err, r.tries, #log }, { 200, nil, 3, 3 })
    r = c:get("https://x/b")
    eq({ r.status, r.tries }, { 200, 2 })
end)

test("http: retries stop after 3 tries; real answers (404, 403, sign-in) aren't retried", function()
    local log = {}
    local c = Http.new{ transport = fakeTransport({ ["https://x/a"] = { 500, {}, "" }, ["https://x/nf"] = { 404, {}, "" },
        ["https://x/fw"] = { 403, {}, "" } }, log) }
    eq({ c:get("https://x/a").err, #log }, { "server", 3 })
    eq({ c:get("https://x/nf").err, #log }, { "not_found", 4 })
    eq({ c:get("https://x/fw").err, #log }, { "blocked", 5 })
end)

test("http: failures are logged with path and status only", function()
    local logged
    package.loaded["logger"] = { warn = function(...) logged = table.concat({ ... }, " ") end }
    Http.new{ transport = fakeTransport({ ["https://www.goodreads.com/review/list?shelf=read"] = { 500, {}, "" } }) }
        :get("https://www.goodreads.com/review/list?shelf=read")
    package.loaded["logger"] = nil
    eq(logged, "BlossomReads http: GET /review/list status 500 err server tries 3")
end)

test("identify: title and author from the Kindle's file names", function()
    eq({ Identify.fromFileName("/mnt/us/Books/Juniper Hale/(2) Moonlit Orchard - Juniper Hale.epub") }, { "Moonlit Orchard", "Juniper Hale" })
    eq({ Identify.fromFileName("/mnt/us/Books/Paper Lanterns - Ada Penrose.epub") }, { "Paper Lanterns", "Ada Penrose" })
    eq({ Identify.fromFileName("/mnt/us/Books/Lantern Saga/The Keeper's Lantern.epub") }, { "The Keeper's Lantern" })
    eq({ Identify.fromFileName("/b/A Garden of Small Hours - Mina J. Hart (1).epub") }, { "A Garden of Small Hours", "Mina J. Hart" })
    eq({ Identify.fromFileName("/b/Spider-Man - Stan Lee.epub") }, { "Spider-Man", "Stan Lee" })
    eq({ Identify.fromFileName("/b/Nausea - Jean-Paul Sartre.epub") }, { "Nausea", "Jean-Paul Sartre" })
end)

test("identify: a never-opened book is described by its file name", function()
    eq(Identify.fromProps(nil, "/b/(3) Starlit Harbor - Juniper Hale.epub"), { title = "Starlit Harbor", author = "Juniper Hale" })
    -- real metadata wins over the file name
    eq(Identify.fromProps({ title = "Starlit Harbor", authors = "Juniper Hale\nX" }, "/b/whatever.epub"), { title = "Starlit Harbor", author = "Juniper Hale" })
end)

test("api: taking a book off a shelf posts a=remove", function()
    local log = {}
    local a = api({ [GR .. "/shelf/add_to_shelf"] = { 200, {}, "{}" } }, log)
    eq({ a:unshelf("9", "favorites") }, { true })
    local body = log[#log].body
    assert(body:find("a=remove") and body:find("name=favorites") and body:find("book_id=9"), body)
    a:setShelf("9", "favorites")
    assert(log[#log].body:find("a=&"), log[#log].body)
end)

test("http: JSON writer (objects sorted, empty arrays marked, strings escaped, round trip)", function()
    eq(Http.jsonEncode({ b = 1, a = { 1, 2 }, c = Http.array(), d = {}, e = false, f = 'q"u\\o\nte' }),
        [[{"a":[1,2],"b":1,"c":[],"d":{},"e":false,"f":"q\"u\\o\nte"}]])
    local v = { bookId = "kca://book/x", sessions = { { id = "new-1", endedDate = { year = 2025, month = 11, day = 18 }, startedDate = Http.null } } }
    eq(Http.json(Http.jsonEncode(v)), { bookId = "kca://book/x", sessions = { { id = "new-1", endedDate = { year = 2025, month = 11, day = 18 } } } })
    eq(Http.jsonEncode({ "x", { n = 1.5 } }), [=[["x",{"n":1.5}]]=])
    eq(Http.jsonEncode({ startedDate = Http.null }), [[{"startedDate":null}]])
end)

local Review = require("blossomreads_review")
local Fixtures = require("blossomreads_fixtures")
local reviewPage, ACTION_JS = Fixtures.reviewPage, Fixtures.ACTION_JS

-- A fake Goodreads that keeps reading sessions and applies submitted forms.
local function fakeGoodreads(o)
    local state = { sessions = o.sessions, posts = {}, chunk_gets = 0, review = o.review, notes = o.notes, owned = o.owned }
    state.transport = function(req)
        if req.url:find("/review/edit/500$") and req.method == "GET" then
            return 200, {}, reviewPage{ sessions = state.sessions, review = state.review, notes = state.notes, owned = state.owned, shelvings = o.shelvings }
        end
        if req.url:find("/_next/static/chunks/") then
            state.chunk_gets = state.chunk_gets + 1
            if req.url:find("5305%-b%.js$") then return 200, {}, ACTION_JS end
            return 200, {}, "/* nothing here */"
        end
        if req.url:find("/review/edit/500$") and req.method == "POST" then
            state.posts[#state.posts + 1] = req
            if o.ignore_save then return 200, {}, "0:[]" end
            local args = Http.json(req.body)
            local saved = {}
            for i, s in ipairs(args[1].readingSessions) do
                saved[i] = { id = s.id:find("^new%-") and ("kca://reading_session/n" .. i) or s.id, bookId = s.bookId,
                    state = s.state, startedDate = s.startedDate, endedDate = s.endedDate }
            end
            state.sessions = saved
            return 200, { ["content-type"] = "text/x-component" }, "0:{}"
        end
        return 404, {}, ""
    end
    return state
end

test("review: parses the review page (sessions with resolved dates, notes, owned, scripts)", function()
    local page = Review.parse(reviewPage{ notes = 'my "notes"', owned = true, sessions = {
        { id = "s1", bookId = "kca://book/B500", state = "COMPLETED", startedDate = { year = 2025, month = 9, day = 28 }, endedDate = { year = 2025, month = 11, day = 18 } } } }, 500)
    eq({ page.book_id, page.has_review, page.notes, page.owned }, { "kca://book/B500", false, 'my "notes"', true })
    eq(page.sessions[1].endedDate, { year = 2025, month = 11, day = 18 })
    eq(#page.scripts, 4)
    eq(Review.parse(reviewPage{ review = true }, 500).has_review, true)
end)

test("review: finds your other edition already on a shelf", function()
    local page = Review.parse(reviewPage{ shelvings = {
        { book = { id = "kca://book/HC", legacyId = 222 }, shelf = { name = "read" }, readingSessions = {} },
        { book = { id = "kca://book/B500", legacyId = 500 }, shelf = { name = "read" }, readingSessions = {} } } }, 500)
    eq({ Review.ownEdition(page) }, { "222", "read" })
    eq(Review.ownEdition(Review.parse(reviewPage{}, 500)), nil)
end)

test("review: first read fills in the undated session Goodreads made; saved and checked", function()
    local gr = fakeGoodreads{ sessions = { { id = "kca://reading_session/s1", bookId = "kca://book/B500", state = "COMPLETED" } }, notes = "kept" }
    local http, cache = Http.new{ transport = gr.transport }, {}
    local d = { ended = Review.date("2026-09-02"), started = Review.date("2026-08-20") }
    eq({ Review.addRead(http, 500, d, "first", cache) }, { true, "saved" })
    eq(gr.sessions, { { id = "kca://reading_session/s1", bookId = "kca://book/B500", state = "COMPLETED",
        startedDate = { year = 2026, month = 8, day = 20 }, endedDate = { year = 2026, month = 9, day = 2 } } })
    local post = gr.posts[1]
    eq({ post.headers["Next-Action"], post.headers["Content-Type"], post.headers["Accept"] },
        { "6036dfbeef", "text/plain;charset=UTF-8", "text/x-component" })
    local args = Http.json(post.body)
    eq({ args[2], args[1].reviewText, args[1].privateNotes, args[1].addToUpdateFeed, args[1].postToBlog, args[1].bookId },
        { "/review/edit/[id]", "", "kept", false, false, "kca://book/B500" })
    assert(post.body:find('"startedDate":null', 1, true), "initial sessions keep explicit nulls")
    eq(cache, { id = "6036dfbeef", chunk = "/_next/static/chunks/5305-b.js" })
    eq(gr.chunk_gets, 2) -- the route chunk first, then 5305
end)

test("review: action id is remembered until the page's scripts change", function()
    local gr = fakeGoodreads{ sessions = {} }
    local http, cache = Http.new{ transport = gr.transport }, { id = "6036dfbeef", chunk = "/_next/static/chunks/5305-b.js" }
    Review.addRead(http, 500, { ended = Review.date("2026-01-05") }, "first", cache)
    eq(gr.chunk_gets, 0)
    cache.chunk = "/_next/static/chunks/old.js"
    Review.addRead(http, 500, { ended = Review.date("2026-02-05") }, "reread", cache)
    eq(gr.chunk_gets, 2)
end)

test("review: already dated (any edition) → nothing is written for a first read", function()
    local gr = fakeGoodreads{ sessions = { { id = "s1", bookId = "kca://book/HC", state = "COMPLETED", endedDate = { year = 2025, month = 11, day = 18 } } } }
    eq({ Review.addRead(Http.new{ transport = gr.transport }, 500, { ended = Review.date("2026-09-02") }, "first", {}) }, { true, "dated" })
    eq(#gr.posts, 0)
end)

test("review: a reread adds a new read date, once", function()
    local gr = fakeGoodreads{ sessions = { { id = "s1", bookId = "kca://book/B500", state = "COMPLETED", endedDate = { year = 2025, month = 11, day = 18 } } } }
    local http, cache = Http.new{ transport = gr.transport }, {}
    local d = { ended = Review.date("2026-03-01"), started = Review.date("2026-02-10") }
    eq({ Review.addRead(http, 500, d, "reread", cache) }, { true, "saved" })
    eq(#gr.sessions, 2)
    eq({ Review.addRead(http, 500, d, "reread", cache) }, { true, "already" })
    eq(#gr.posts, 1)
end)

test("review: an edition with a review is never written", function()
    local gr = fakeGoodreads{ sessions = {}, review = true }
    eq({ Review.addRead(Http.new{ transport = gr.transport }, 500, { ended = Review.date("2026-09-02") }, "first", {}) }, { nil, "has_review" })
    eq(#gr.posts, 0)
end)

test("review: a save Goodreads didn't apply is reported, and the action id is looked up again", function()
    local gr = fakeGoodreads{ sessions = {}, ignore_save = true }
    local cache = {}
    eq({ Review.addRead(Http.new{ transport = gr.transport }, 500, { ended = Review.date("2026-09-02") }, "first", cache) }, { nil, "unexpected" })
    eq(cache, {})
end)

test("review: dates", function()
    eq(Review.date("2026-09-02"), { year = 2026, month = 9, day = 2 })
    eq(Review.date("someday"), nil)
end)

H.done()
