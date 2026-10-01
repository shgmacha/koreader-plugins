-- Made-up Goodreads pages for Blossom Reads tests (no real data).
local Http = require("blossomreads_http")
local F = {}

F.ACTION_JS = 'let z=(0,P.createServerReference)("60c0aa",P.callServer,void 0,P.findSourceMapURL,"updateReviewDraftAction"),'
    .. 'O=(0,P.createServerReference)("6036dfbeef",P.callServer,void 0,P.findSourceMapURL,"submitReviewFormAction");'

-- A review page shaped like Goodreads' (RSC flight data in self.__next_f.push).
-- o = { gid, sessions, shelvings, review, notes, owned }
function F.reviewPage(o)
    o = o or {}
    local gid = tostring(o.gid or "500")
    local book = "kca://book/B" .. gid
    local sessions = o.sessions or { { id = "kca://reading_session/s1", bookId = book, state = "COMPLETED" } }
    local shelvings = o.shelvings or { { book = { id = book, legacyId = tonumber(gid) }, shelf = { name = "read" }, readingSessions = sessions } }
    local form = {}
    for i, s in ipairs(sessions) do
        form[i] = { id = s.id, bookId = s.bookId, state = s.state,
            startedDate = "$2b:props:book:work:viewerShelvings:0:readingSessions:" .. (i - 1) .. ":startedDate",
            endedDate = "$2b:props:book:work:viewerShelvings:0:readingSessions:" .. (i - 1) .. ":endedDate",
            edition = { legacyId = tonumber(gid) } }
    end
    local payload = '1:{"book":{"id":"' .. book .. '","legacyId":' .. gid .. ',"work":{"viewerShelvings":'
        .. Http.jsonEncode(Http.array(shelvings)) .. '}},'
        .. (o.review and '"review":{"id":"kca://review/r1"},' or '"review":null,')
        .. '"draftConfig":{"enabled":true},"isAlreadyOwned":' .. tostring(o.owned or false)
        .. ',"initialPrivateNotes":' .. Http.jsonEncode(o.notes or "") .. ',"initialReadingSessions":'
        .. Http.jsonEncode(Http.array(form)) .. ',"routePath":"/review/edit/[id]"}'
    local half = math.floor(#payload / 2)
    return '<html><script src="/_next/static/chunks/polyfills-1.js"></script>'
        .. '<script src="/_next/static/chunks/4968-a.js"></script><script src="/_next/static/chunks/5305-b.js"></script>'
        .. '<script src="/_next/static/chunks/app/review/edit/%5Bid%5D/page-c.js"></script>'
        .. '<script>self.__next_f.push([1,' .. Http.jsonEncode(payload:sub(1, half)) .. '])</script>'
        .. '<script>self.__next_f.push([1,' .. Http.jsonEncode(payload:sub(half + 1)) .. '])</script></html>'
end

-- Apply a submitted review form to a list of sessions, like Goodreads does.
function F.applySave(body)
    local args = Http.json(body)
    local saved = {}
    for i, s in ipairs(args[1].readingSessions) do
        saved[i] = { id = s.id:find("^new%-") and ("kca://reading_session/n" .. i .. "-" .. os.clock()) or s.id,
            bookId = s.bookId, state = s.state, startedDate = s.startedDate, endedDate = s.endedDate }
    end
    return saved, args
end

return F
