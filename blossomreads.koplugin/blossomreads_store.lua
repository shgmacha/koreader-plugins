--[[--
Small per-concern files under settings/blossomreads/ (session, books, credentials).

The folder is created before the first write: KOReader's LuaSettings:flush()
silently writes nothing when it is missing, which is why goodreadskosync's
login never stuck.
--]]

local Store = {}

local dir_override
local ensured = {}

local function settings_dir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then return DataStorage:getSettingsDir() end
    return "."
end

function Store.dir()
    return dir_override or (settings_dir() .. "/blossomreads")
end

-- Tests point the store at a temp folder and use the plain serializer.
function Store.setDir(dir)
    dir_override = dir
    ensured = {}
end

function Store.ensureDir(dir)
    dir = dir or Store.dir()
    if ensured[dir] then return end
    local ok, util = pcall(require, "ffi/util")
    if not (ok and util and util.makePath and pcall(util.makePath, dir)) then
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    ensured[dir] = true
end

local function serialize(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end
Store.serialize = serialize

local File = {}
File.__index = File

function File:get(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return v
end

function File:set(key, value)
    self.data[key] = value
    self.dirty = true
end

function File:delete(key)
    self.data[key] = nil
    self.dirty = true
end

function File:flush()
    if not self.dirty then return true end
    Store.ensureDir()
    local ok
    if self.ls then
        -- Replace LuaSettings' table so deleted keys don't come back.
        self.ls.data = self.data
        ok = pcall(self.ls.flush, self.ls)
    else
        local f = io.open(self.path, "w")
        ok = f ~= nil
        if f then
            f:write("return ", serialize(self.data), "\n")
            f:close()
        end
    end
    if ok then self.dirty = false end
    return ok
end

function Store.open(name)
    local path = Store.dir() .. "/" .. name .. ".lua"
    local ok, LuaSettings = pcall(require, "luasettings")
    if ok and LuaSettings and not dir_override then
        local ls = LuaSettings:open(path)
        return setmetatable({ path = path, ls = ls, data = ls.data or {} }, File)
    end
    local data = {}
    local chunk = loadfile(path)
    if chunk then
        local ran, loaded = pcall(chunk)
        if ran and type(loaded) == "table" then data = loaded end
    end
    return setmetatable({ path = path, data = data }, File)
end

-- Remove one store file (sign-out, forget password).
function Store.remove(name)
    os.remove(Store.dir() .. "/" .. name .. ".lua")
end

return Store
