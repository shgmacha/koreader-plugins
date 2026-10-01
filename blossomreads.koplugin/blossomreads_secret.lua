--[[--
Secrets at rest: AES-256-CBC through the libcrypto KOReader already ships.

Keeps cookies and the optional saved password out of plain sight in settings
files that may be shared for support. It is not protection against someone
with full filesystem access (KOReader has no keystore). Without libcrypto,
values are stored as plain text.
--]]

local Store = require("blossomreads_store")

local Secret = {}

local ffi_ok, ffi = pcall(require, "ffi")
local lib -- nil = not tried, false = unavailable
local cached_key -- only a real key is cached, never "no key yet"
local declared = false

local function cdef()
    if declared then return end
    declared = true
    ffi.cdef([[
        typedef struct engine_st ENGINE;
        typedef struct evp_cipher_st EVP_CIPHER;
        typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
        EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
        void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
        int EVP_CipherInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *, int);
        int EVP_CipherUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
        int EVP_CipherFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
        const EVP_CIPHER *EVP_aes_256_cbc(void);
        int RAND_bytes(unsigned char *, int);
    ]])
end

-- Only KOReader's ffi.loadlib is used: a bare ffi.load("crypto") aborts on macOS.
local function crypto()
    if lib == nil then
        lib = false
        if ffi_ok and ffi.loadlib then
            local ok, l = pcall(function() cdef(); return ffi.loadlib("crypto", "57") end)
            if ok and l then lib = l end
        end
    end
    return lib or nil
end

-- Tests inject a libcrypto loaded by full path.
function Secret._setLib(l)
    if l then cdef() end
    lib = l or false
    cached_key = nil
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function unhex(s)
    if type(s) ~= "string" or #s % 2 ~= 0 or s:find("[^%x]") then return nil end
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function random(l, n)
    local buf = ffi.new("unsigned char[?]", n)
    if l.RAND_bytes(buf, n) ~= 1 then return nil end
    return ffi.string(buf, n)
end

local function cipher(l, data, key, iv, encrypt)
    local ctx = l.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end
    local out = ffi.new("unsigned char[?]", #data + 32)
    local n1, n2 = ffi.new("int[1]"), ffi.new("int[1]")
    local ok = l.EVP_CipherInit_ex(ctx, l.EVP_aes_256_cbc(), nil, key, iv, encrypt and 1 or 0) == 1
        and l.EVP_CipherUpdate(ctx, out, n1, data, #data) == 1
        and l.EVP_CipherFinal_ex(ctx, out + n1[0], n2) == 1
    l.EVP_CIPHER_CTX_free(ctx)
    if not ok then return nil end
    return ffi.string(out, n1[0] + n2[0])
end

local function key(l)
    if cached_key then return cached_key end
    -- Re-read every time until a key exists, so another process's new key is seen.
    local ring = Store.open("keyring")
    local k = unhex(ring:get("key"))
    if not k or #k ~= 32 then
        k = random(l, 32)
        if not k then return nil end
        ring:set("key", hex(k))
        if not ring:flush() then return nil end
    end
    cached_key = k
    return k
end

-- Returns stored value, encrypted?
function Secret.protect(plain)
    if type(plain) ~= "string" or plain == "" then return plain, false end
    local l = crypto()
    local k = l and key(l)
    local iv = k and random(l, 16)
    local blob = iv and cipher(l, plain, k, iv, true)
    if not blob then return plain, false end
    return hex(iv .. blob), true
end

-- Returns the plain value, or nil when it can't be decrypted.
function Secret.unprotect(value, encrypted)
    if not encrypted then return value end
    local l = crypto()
    local raw = unhex(value)
    if not (l and raw and #raw > 16) then return nil end
    local k = key(l)
    return k and cipher(l, raw:sub(17), k, raw:sub(1, 16), false) or nil
end

return Secret
