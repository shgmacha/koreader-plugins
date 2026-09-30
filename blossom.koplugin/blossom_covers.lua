--[[--
Finds book covers for statistics entries. The statistics DB only knows a
book's partial MD5, so files from the reading history are matched lazily
(only as far as needed) and cached for the session.
--]]

local logger = require("logger")

local Covers = {}
Covers.__index = Covers

--- deps are injectable for tests; defaults are the real KOReader modules.
function Covers.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Covers)
    self.history = deps.history or function() return require("readhistory").hist or {} end
    self.fileExists = deps.fileExists or function(file)
        return require("libs/libkoreader-lfs").attributes(file, "mode") == "file"
    end
    self.md5Of = deps.md5Of or function(file)
        local md5 = require("docsettings"):open(file):readSetting("partial_md5_checksum")
        return md5 or require("util").partialMD5(file)
    end
    self.coverOf = deps.coverOf or Covers.loadCoverBB
    self.map = {}
    self.scanned = 0
    return self
end

function Covers:pathFor(md5)
    if not md5 then return end
    if self.map[md5] then return self.map[md5] end
    local hist = self.history()
    while self.scanned < #hist do
        self.scanned = self.scanned + 1
        local file = hist[self.scanned].file
        if file and self.fileExists(file) then
            local ok, sum = pcall(self.md5Of, file)
            if ok and sum then
                self.map[sum] = self.map[sum] or file
                if sum == md5 then return file end
            end
        end
    end
end

--- Cover Browser's thumbnails smaller than this are only a fallback: they'd look blurry scaled up.
Covers.SHARP_HEIGHT = 400

--- A sharp cover: Cover Browser's cache when its thumbnail is big enough, else from the book itself,
--- else whatever thumbnail there is.
function Covers.loadCoverBB(file)
    local thumb
    local bim = package.loaded["bookinfomanager"]
    if bim then
        local ok, info = pcall(bim.getBookInfo, bim, file, true)
        if ok and info and info.has_cover and info.cover_bb then
            thumb = info.cover_bb
            if thumb:getHeight() >= Covers.SHARP_HEIGHT then return thumb end
        end
    end
    local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if ok then
        local ok2, bb = pcall(BookInfo.getCoverImage, BookInfo, nil, file)
        if ok2 and bb then
            if thumb and thumb.free then thumb:free() end
            return bb
        end
        if not ok2 then logger.warn("Blossom: cover extraction failed", file, bb) end
    end
    return thumb
end

--- Returns a fresh blitbuffer (caller owns it) or nil.
function Covers:coverFor(md5)
    local file = self:pathFor(md5)
    if not file then return end
    local ok, bb = pcall(self.coverOf, file)
    if ok then return bb end
end

return Covers
