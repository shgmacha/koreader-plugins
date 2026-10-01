--[[--
Goodreads sign-in (Amazon sign-in pages) and the saved session.

Runs in KOReader's own process, so a sign-in that needs a code or a picture
puzzle keeps its half-finished state (`pending`) between the steps. In
goodreadskosync that state lived in a forked child and was lost.

Results:
  { ok = true, user_id = "123" }
  { need = "otp" } | { need = "captcha", image_url = "…" }
  { err = "credentials" | "blocked" | "network" | "server" | "unexpected" }
--]]

local Http = require("blossomreads_http")
local Secret = require("blossomreads_secret")
local Store = require("blossomreads_store")

local Login = {}

local BASE = "https://www.goodreads.com"
local pending -- { http, form, last_body, last_url, captcha }

local CAPTCHA_TEXT = { "enter the characters you see", "type the characters you see", "characters you see" }
local OTP_TEXT = { "auth-mfa", "otpcode", "verification code", "two-step verification", "enter otp" }
local BAD_LOGIN_TEXT = {
    "password is incorrect", "problem with your password", "cannot find an account",
    "there was a problem with your request",
}

local function has(body, list)
    local l = (body or ""):lower()
    for _, s in ipairs(list) do
        if l:find(s, 1, true) then return true end
    end
    return false
end

local function attr(tag, name)
    return tag:match(name .. '="([^"]*)"') or tag:match(name .. "='([^']*)'")
end

local function decode(s)
    return s and (s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"))
end

local function hidden(inner)
    local fields = {}
    for tag in inner:gmatch("<input[^>]*>") do
        if (attr(tag, "type") or ""):lower() == "hidden" then
            local name = attr(tag, "name")
            if name then fields[name] = decode(attr(tag, "value")) or "" end
        end
    end
    return fields
end

local function inputNamed(inner, candidates)
    for _, n in ipairs(candidates) do
        if inner:find('name="' .. n .. '"', 1, true) or inner:find("name='" .. n .. "'", 1, true) then
            return n
        end
    end
end

local function forms(html)
    return (html or ""):gmatch("<form([^>]*)>(.-)</form>")
end

-- The sign-in form: email + password, or email only (Amazon's two-page flow).
function Login._parseSigninForm(html)
    for attrs, inner in forms(html) do
        local email = inputNamed(inner, { "user[email]", "ap_email", "email" })
        local password = inputNamed(inner, { "user[password]", "ap_password", "password" })
        local has_password = inner:find("type=[\"']password[\"']") ~= nil
        if has_password or email then
            local remember
            for tag in inner:gmatch("<input[^>]*>") do
                local name = attr(tag, "name")
                if name and name:lower():find("remember", 1, true) then remember = name; break end
            end
            return {
                action = decode(attr(attrs, "action")),
                hidden = hidden(inner),
                email = email or "email",
                password = has_password and (password or "password") or nil,
                remember = remember,
            }
        end
    end
end

function Login._parseOtpForm(html)
    for attrs, inner in forms(html) do
        local field = inner:match('name="(otpCode)"') or inner:match('name="(code)"')
            or inner:match('name="([^"]*otp[^"]*)"')
        if field then
            return { action = decode(attr(attrs, "action")), hidden = hidden(inner), field = field }
        end
    end
end

-- A picture puzzle: the image may sit outside the form, so find each separately.
function Login._parseCaptcha(html)
    local image
    for tag in (html or ""):gmatch("<img[^>]*>") do
        local src = attr(tag, "src")
        local l = (src or ""):lower()
        if l:find("captcha", 1, true) or l:find("/errors/validate", 1, true) then image = decode(src); break end
    end
    if not image then return nil end
    local fallback
    for attrs, inner in forms(html) do
        for tag in inner:gmatch("<input[^>]*>") do
            local typ = (attr(tag, "type") or "text"):lower()
            local name = attr(tag, "name")
            if name and (typ == "text" or typ == "search") then
                local found = { action = decode(attr(attrs, "action")), hidden = hidden(inner), field = name, image_url = image }
                local l = name:lower()
                if l:find("captcha", 1, true) or l:find("keyword", 1, true) then return found end
                fallback = fallback or found
            end
        end
    end
    return fallback
end

-- Goodreads' sign-in page links to Amazon's; skip the "sign in with Apple/…" ones.
function Login._signinLink(html)
    local first
    for href in (html or ""):gmatch("href=[\"'](https?://[^\"']*/ap/signin%?[^\"']*)[\"']") do
        href = decode(href)
        if not href:find("identityProvider", 1, true) then return href end
        first = first or href
    end
    return first
end

--------------------------------------------------------------------------------
-- Session (cookies, encrypted) and remembered password
--------------------------------------------------------------------------------

function Login.session()
    local s = Store.open("session")
    local cookies = s:get("cookies")
    if s:get("encrypted") then cookies = Secret.unprotect(cookies, true) end
    return {
        cookies = cookies or "",
        user_id = s:get("user_id"),
        state = s:get("state") or "none",
    }
end

function Login.signedIn()
    local s = Login.session()
    return s.state == "valid" and s.cookies ~= "" and s.user_id ~= nil
end

function Login.saveSession(cookies, user_id, state)
    local s = Store.open("session")
    local blob, encrypted = Secret.protect(cookies)
    s:set("cookies", blob)
    s:set("encrypted", encrypted)
    s:set("user_id", user_id)
    s:set("state", state or "valid")
    s:set("updated_at", os.time())
    return s:flush()
end

function Login.markExpired()
    local s = Store.open("session")
    if s:get("state") == "valid" then
        s:set("state", "expired")
        s:flush()
    end
end

function Login.signOut()
    pending = nil
    Store.remove("session")
end

function Login.saveCredentials(email, password)
    local s = Store.open("credentials")
    local blob, encrypted = Secret.protect(password)
    s:set("email", email)
    s:set("password", blob)
    s:set("encrypted", encrypted)
    return s:flush()
end

function Login.credentials()
    local s = Store.open("credentials")
    local email, password = s:get("email"), s:get("password")
    if s:get("encrypted") then password = Secret.unprotect(password, true) end
    if email and password and password ~= "" then return { email = email, password = password } end
end

function Login.forgetCredentials()
    Store.remove("credentials")
end

--------------------------------------------------------------------------------
-- Sign-in steps
--------------------------------------------------------------------------------

-- Confirm on a normal page that we're signed in, then save the session.
local function finish(http)
    local r = http:get(BASE .. "/review/list", { signin_ok = true })
    if r.err == Http.ERR.BLOCKED or r.err == Http.ERR.NETWORK then return { err = r.err } end
    local user_id = (r.body or ""):match("/user/show/(%d+)")
    if r.err or not user_id or r.url:find("sign_?in") or http.cookies == "" then return { err = "credentials" } end
    pending = nil
    Login.saveSession(http.cookies, user_id, "valid")
    return { ok = true, user_id = user_id }
end

local function post(form, fields, base_url)
    local all = {}
    for k, v in pairs(form.hidden or {}) do all[k] = v end
    for k, v in pairs(fields) do all[k] = v end
    local url = Http.absolute(base_url, form.action or base_url)
    return pending.http:post(url, all, { signin_ok = true })
end

-- Decide what an Amazon answer means.
local function interpret(r)
    if r.err == Http.ERR.NETWORK or r.err == Http.ERR.SERVER then return { err = r.err } end
    local body = r.body or ""
    pending.last_body, pending.last_url = body, r.url
    local captcha = Login._parseCaptcha(body)
    if captcha then
        pending.captcha = captcha
        return { need = "captcha", image_url = Http.absolute(r.url, captcha.image_url) }
    end
    if has(body, CAPTCHA_TEXT) then return { err = "blocked" } end
    if has(body, OTP_TEXT) and Login._parseOtpForm(body) then return { need = "otp" } end
    if has(body, BAD_LOGIN_TEXT) then return { err = "credentials" } end
    local form = Login._parseSigninForm(body)
    if form and form.password then
        -- Two-page sign-in: the email was accepted, now the password page.
        if pending.form and not pending.form.password and pending.password then
            pending.form = form
            local pw = pending.password
            pending.password = nil
            return interpret(post(form, { [form.password] = pw }, r.url))
        end
        return { err = "credentials" }
    end
    -- Amazon's answer was a firewall page: the session may still be fine.
    return finish(pending.http)
end

function Login.start(email, password, opts)
    opts = opts or {}
    if (email or "") == "" or (password or "") == "" then return { err = "credentials" } end
    local http = Http.new{ transport = opts.transport }
    pending = { http = http }
    local r = http:get(BASE .. "/user/sign_in", { signin_ok = true })
    if r.err then return { err = r.err } end
    local form = Login._parseSigninForm(r.body)
    local page_url = r.url
    if not form then
        local link = Login._signinLink(r.body)
        if not link then return { err = "unexpected" } end
        r = http:get(link, { signin_ok = true })
        if r.err then return { err = r.err } end
        page_url = r.url
        form = Login._parseSigninForm(r.body)
        if not form then
            local captcha = Login._parseCaptcha(r.body)
            if captcha then
                pending.captcha = captcha
                return { need = "captcha", image_url = Http.absolute(r.url, captcha.image_url) }
            end
            return { err = "unexpected" }
        end
    end
    pending.form = form
    local fields = { [form.email] = email }
    if form.password then
        fields[form.password] = password
    else
        pending.password = password
    end
    if form.remember then fields[form.remember] = "true" else fields.rememberMe = "true" end
    return interpret(post(form, fields, page_url))
end

function Login.submitOtp(code)
    if not pending then return { err = "unexpected" } end
    local form = Login._parseOtpForm(pending.last_body)
    if not form or (code or "") == "" then return { err = "unexpected" } end
    local fields = { [form.field] = code }
    fields.rememberDevice = "true"
    return interpret(post(form, fields, pending.last_url))
end

function Login.submitCaptcha(answer)
    if not (pending and pending.captcha) or (answer or "") == "" then return { err = "unexpected" } end
    local c = pending.captcha
    pending.captcha = nil
    return interpret(post(c, { [c.field] = answer }, pending.last_url))
end

-- The puzzle picture, fetched with the sign-in cookies.
function Login.captchaImage(url)
    if not pending then return nil end
    local r = pending.http:get(url, { signin_ok = true })
    if r.err or not r.body or r.body == "" then return nil end
    return r.body
end

function Login.cancel()
    pending = nil
end

function Login.pending()
    return pending ~= nil
end

return Login
