-- xpeta: XP progress tracker
-- Written to run on Lua 5.0 (1.12 client) as well as later clients:
-- no '#', '%' operator, select(), or string.match; event args read from globals as fallback.

local ADDON = "xpeta"
local KILL_HISTORY = 5
local MIN_RATE_SPAN = 60 -- seconds; avoids absurd XP/h from two quick gains

local DEFAULTS = { window = 15, locked = false, shown = true, scale = 1, alpha = 0.5 }

local db, chardb
local gains = {}        -- rolling window of { t = GetTime(), xp = n }
local anchor            -- time of the gain the XP/h clock started from
local lastXP, lastMax, lastLevel

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function commas(n)
    local s = tostring(math.floor(n + 0.5))
    local k
    repeat
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return s
end

local function formatETA(seconds)
    if not seconds or seconds <= 0 or seconds > 999 * 3600 then return "--" end
    local total = math.ceil(seconds / 60) -- round up: never show "0m"
    local h = math.floor(total / 60)
    local m = total - h * 60
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100xpeta:|r " .. msg)
end

-- Build a Lua pattern from the client's localized kill-XP string,
-- e.g. "%s dies, you gain %d experience." -> ".+ dies, you gain (%d+) experience%."
local killPattern
do
    local f = COMBATLOG_XPGAIN_FIRSTPERSON
    if type(f) == "string" then
        f = string.gsub(f, "%%%d?%$?s", "\001")
        f = string.gsub(f, "%%%d?%$?d", "\002")
        f = string.gsub(f, "([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
        f = string.gsub(f, "\001", ".+")
        f = string.gsub(f, "\002", "(%%d+)")
        killPattern = f
    end
end

local function parseKillXP(msg)
    local xp
    if killPattern then
        local _, _, v = string.find(msg, killPattern)
        xp = v
    end
    if not xp then
        local _, _, v = string.find(msg, " dies.-(%d+)")
        xp = v
    end
    return tonumber(xp)
end

------------------------------------------------------------------------
-- XP math
------------------------------------------------------------------------

local function prune(now)
    local cutoff = now - db.window * 60
    while gains[1] and gains[1].t < cutoff do
        table.remove(gains, 1)
    end
end

-- XP/h = all XP gained since the first gain of the session (that gain included,
-- kill or quest) over the time since it. Once that span reaches the window it
-- rolls. Returns nil before the first gain.
local function xpPerHour()
    local now = GetTime()
    prune(now)
    if not gains[1] then return nil end
    local sum = 0
    for i = 1, table.getn(gains) do
        sum = sum + gains[i].xp
    end
    local span = now - math.max(anchor, now - db.window * 60)
    if span < MIN_RATE_SPAN then span = MIN_RATE_SPAN end
    return sum * 3600 / span
end

local function avgKill()
    local kills = chardb.kills
    local n = table.getn(kills)
    if n == 0 then return nil, 0 end
    local sum = 0
    for i = 1, n do sum = sum + kills[i] end
    return sum / n, n
end

local function killsToLevel(remaining, perKill)
    if not perKill or perKill <= 0 then return "--" end
    return commas(math.ceil(remaining / perKill))
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

local frame = CreateFrame("Frame", "XpetaFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:Hide()

local PAD_X, PAD_Y, GAP = 12, 10, 3

local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -PAD_Y)
header:SetJustifyH("LEFT")

local line1 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
line1:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -GAP)
line1:SetJustifyH("LEFT")

local line2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
line2:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 0, -GAP)
line2:SetJustifyH("LEFT")

local line3 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
line3:SetPoint("TOPLEFT", line2, "BOTTOMLEFT", 0, -GAP)
line3:SetJustifyH("LEFT")
line3:SetTextColor(0.6, 0.6, 0.6)

local lines = { header, line1, line2, line3 }

local function layout()
    local w, h = 0, 0
    for i = 1, 4 do
        local fs = lines[i]
        local sw = fs:GetStringWidth()
        if sw > w then w = sw end
        h = h + fs:GetHeight()
    end
    frame:SetWidth(math.ceil(w) + PAD_X * 2)
    frame:SetHeight(math.ceil(h) + GAP * 3 + PAD_Y * 2)
end

local SEP = "  |  "

local function update()
    if not db then return end
    local cur, max = UnitXP("player"), UnitXPMax("player")
    local atCap = (not max or max <= 0)
        or (MAX_PLAYER_LEVEL and UnitLevel("player") >= MAX_PLAYER_LEVEL)

    if atCap then
        header:SetText(ADDON .. " (max level)")
        line1:SetText("")
        line2:SetText("")
        line3:SetText("")
        layout()
        return
    end

    local remaining = max - cur
    header:SetText(string.format("%s (%.2f%%)", ADDON, cur / max * 100))

    local kills = chardb.kills
    local last = kills[table.getn(kills)]
    if last then
        line1:SetText("Last kill: " .. commas(last) .. SEP .. "to level: " .. killsToLevel(remaining, last))
    else
        line1:SetText("Last kill: --" .. SEP .. "to level: --")
    end

    local avg, n = avgKill()
    if avg then
        line2:SetText("Last " .. n .. " kills: " .. commas(avg) .. SEP .. "to level: " .. killsToLevel(remaining, avg))
    else
        line2:SetText("Last " .. KILL_HISTORY .. " kills: --" .. SEP .. "to level: --")
    end

    local rate = xpPerHour()
    if rate then
        line3:SetText("XP/h: " .. commas(rate) .. SEP .. "ETA " .. formatETA(remaining / rate * 3600))
    else
        line3:SetText("XP/h: --" .. SEP .. "ETA --")
    end

    layout()
end

local function savePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    db.point = { point, relPoint, x, y }
end

-- Background opacity only; text stays fully opaque.
local function applyAlpha()
    frame:SetBackdropColor(0.08, 0.07, 0.06, db.alpha)
    frame:SetBackdropBorderColor(0.35, 0.32, 0.28, db.alpha)
end

-- Unlocked: draggable. Locked: click-through so it never blocks the game.
local function applyLock()
    frame:EnableMouse(not db.locked)
end

local function restorePosition()
    frame:ClearAllPoints()
    local p = db.point
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
end

frame:SetScript("OnDragStart", function()
    if not db.locked then frame:StartMoving() end
end)
frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    savePosition()
end)

local elapsedAcc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedAcc = elapsedAcc + (elapsed or arg1 or 0)
    if elapsedAcc >= 1 then
        elapsedAcc = 0
        update()
    end
end)

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- Runs on PLAYER_XP_UPDATE only, where XP, max and level are consistent;
-- during PLAYER_LEVEL_UP the client can still report the old values.
local function onXPUpdate()
    local cur, max, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if lastXP then
        local delta
        if level > lastLevel or cur < lastXP then
            -- leveled up: rest of the old bar plus progress into the new one.
            -- The level check also catches one gain bigger than a whole bar.
            delta = (lastMax - lastXP) + cur
            -- level read stale: count this level-up once, not again later
            if level <= lastLevel then level = lastLevel + 1 end
        else
            delta = cur - lastXP
        end
        if delta > 0 then
            local now = GetTime()
            prune(now)
            -- first gain, or idle longer than the window: restart the clock here
            if not gains[1] then anchor = now end
            table.insert(gains, { t = now, xp = delta })
        end
    end
    lastXP, lastMax, lastLevel = cur, max, level
    update()
end

local function onKillMessage(msg)
    local xp = parseKillXP(msg or "")
    if not xp then return end
    local kills = chardb.kills
    table.insert(kills, xp)
    while table.getn(kills) > KILL_HISTORY do
        table.remove(kills, 1)
    end
    update()
end

local function init()
    XpetaDB = XpetaDB or {}
    for k, v in pairs(DEFAULTS) do
        if XpetaDB[k] == nil then XpetaDB[k] = v end
    end
    XpetaCharDB = XpetaCharDB or {}
    XpetaCharDB.kills = XpetaCharDB.kills or {}
    db, chardb = XpetaDB, XpetaCharDB

    frame:SetScale(db.scale)
    applyAlpha()
    applyLock()
    restorePosition()
    if db.shown then frame:Show() end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")

frame:SetScript("OnEvent", function(_, ev, a1)
    ev = ev or event
    a1 = a1 or arg1
    if ev == "ADDON_LOADED" then
        if a1 == ADDON then init() end
    elseif not db then
        return
    elseif ev == "PLAYER_ENTERING_WORLD" then
        if not lastXP then
            lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
        end
        update()
    elseif ev == "PLAYER_XP_UPDATE" then
        onXPUpdate()
    elseif ev == "CHAT_MSG_COMBAT_XP_GAIN" then
        onKillMessage(a1)
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

SLASH_XPETA1 = "/xpeta"
SlashCmdList["XPETA"] = function(msg)
    local _, _, cmd, rest = string.find(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    local num = tonumber(rest)

    if cmd == "show" or cmd == "hide" or cmd == "toggle" then
        if cmd == "toggle" then db.shown = not db.shown else db.shown = (cmd == "show") end
        if db.shown then frame:Show(); update() else frame:Hide() end
    elseif cmd == "lock" then
        db.locked = true
        applyLock()
        print("frame locked (click-through).")
    elseif cmd == "unlock" then
        db.locked = false
        applyLock()
        print("frame unlocked, drag to move.")
    elseif cmd == "alpha" and num and num >= 0 and num <= 1 then
        db.alpha = num
        applyAlpha()
    elseif cmd == "window" and num and num >= 1 then
        db.window = num
        print("rolling window set to " .. num .. " min.")
        update()
    elseif cmd == "scale" and num and num >= 0.5 and num <= 3 then
        db.scale = num
        frame:SetScale(num)
    elseif cmd == "reset" then
        gains = {}
        anchor = nil
        chardb.kills = {}
        print("session data reset.")
        update()
    elseif cmd == "resetpos" then
        db.point = nil
        restorePosition()
    else
        print("/xpeta show | hide | toggle | lock | unlock | reset | resetpos")
        print("/xpeta window <minutes> (now " .. db.window .. ") | scale <0.5-3> (now " .. db.scale
            .. ") | alpha <0-1> (now " .. db.alpha .. ")")
    end
end
