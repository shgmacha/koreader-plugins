-- Tiny test harness for plain LuaJIT (no busted on this machine).
local H = { passed = 0, failed = 0 }

local function show(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = (type(k) == "number" and "" or tostring(k) .. "=") .. show(v[k])
    end
    return "{" .. table.concat(out, ", ") .. "}"
end
H.show = show

function H.eq(got, want, msg)
    if show(got) ~= show(want) then
        error(string.format("%s\n    got:  %s\n    want: %s", msg or "not equal", show(got), show(want)), 2)
    end
end

function H.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        H.passed = H.passed + 1
        print("ok   " .. name)
    else
        H.failed = H.failed + 1
        print("FAIL " .. name .. "\n  " .. tostring(err))
    end
end

function H.done()
    print(string.format("\n%d passed, %d failed", H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

-- Run from the repo root: make plugin modules requirable.
package.path = "./blossom.koplugin/?.lua;./tests/?.lua;" .. package.path

return H
