WA_SafeGuardDB = WA_SafeGuardDB or {}

local P = "|cff00ccff[SafeGuard]|r "

----------------------------------------------------------------
-- Serializergit add: per-chunk, no giant allocations
----------------------------------------------------------------
local B, N

local function w(v, seen, depth)
    if depth > 80 then N=N+1; B[N]="nil"; return end

    local t = type(v)

    if t == "table" then
        if seen[v] then N=N+1; B[N]="nil"; return end
        seen[v] = true

        N=N+1; B[N]="{"
        for k, val in pairs(v) do
            local kt = type(k)
            local vt = type(val)
            if (kt=="string" or kt=="number" or kt=="boolean")
               and vt~="function" and vt~="userdata" and vt~="thread" then
                N=N+1; B[N]="["
                w(k, seen, depth+1)
                N=N+1; B[N]="]="
                w(val, seen, depth+1)
                N=N+1; B[N]=","
            end
        end
        N=N+1; B[N]="}"
        seen[v] = nil

    elseif t == "string" then
        N=N+1; B[N]=string.format("%q", v)
    elseif t == "number" then
        if v~=v then N=N+1; B[N]="0"
        elseif v==1/0 then N=N+1; B[N]="1e308"
        elseif v==-1/0 then N=N+1; B[N]="-1e308"
        else N=N+1; B[N]=tostring(v) end
    elseif t == "boolean" then
        N=N+1; B[N]=v and "true" or "false"
    else
        N=N+1; B[N]="nil"
    end
end

-- Serialize small table → string (for individual auras)
local function Serialize(tbl)
    B={}; N=0
    w(tbl, {}, 0)
    -- concat in chunks to avoid huge single allocation
    local parts = {}
    local pn = 0
    local CHUNK = 4000
    for i = 1, N, CHUNK do
        local j = i + CHUNK - 1
        if j > N then j = N end
        pn = pn + 1
        parts[pn] = table.concat(B, "", i, j)
    end
    B = nil
    return table.concat(parts)
end

local function Deserialize(s)
    if not s or #s < 2 then return nil end
    local fn = loadstring("return "..s)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, r = pcall(fn)
    return ok and type(r)=="table" and r or nil
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function IsBroken()
    return type(WeakAurasSaved) ~= "table"
        or type(WeakAurasSaved.displays) ~= "table"
end

local function NumAuras(t)
    t = t or WeakAurasSaved
    if type(t)~="table" or type(t.displays)~="table" then return 0 end
    local c=0; for _ in pairs(t.displays) do c=c+1 end; return c
end

local function HasBackup()
    return type(WA_SafeGuardDB)=="table"
        and type(WA_SafeGuardDB.displays)=="table"
        and next(WA_SafeGuardDB.displays) ~= nil
end

----------------------------------------------------------------
-- Backup: each aura serialized individually (small strings)
----------------------------------------------------------------
local function DoBackup(silent)
    if IsBroken() then
        if not silent then print(P.."|cffff0000WA data broken, cannot backup|r") end
        return false
    end

    local saved = WeakAurasSaved
    local db = {
        displays = {},
        meta     = {},
        n        = 0,
        t        = time(),
    }

    -- backup each aura individually — no giant string
    local count = 0
    local errors = 0
    for name, aura in pairs(saved.displays) do
        local ok, s = pcall(Serialize, aura)
        if ok and s and #s > 2 then
            db.displays[name] = s
            count = count + 1
        else
            errors = errors + 1
        end
    end

    -- backup small meta fields (not displays, not caches)
    local skipKeys = {
        displays=true, registered=true, tempIconCache=true,
        iconCache=true, loaded=true, newFeaturesSeen=true,
    }
    for k, v in pairs(saved) do
        if not skipKeys[k] then
            local ok, s = pcall(Serialize, {v})
            if ok and s then
                db.meta[k] = s
            end
        end
    end

    db.n = count

    WA_SafeGuardDB = db

    if not silent then
        local totalKB = 0
        for _, s in pairs(db.displays) do totalKB = totalKB + #s end
        for _, s in pairs(db.meta) do totalKB = totalKB + #s end
        totalKB = math.floor(totalKB / 1024)

        local msg = format("|cff00ff00Backup OK|r  %d auras  ~%dKB", count, totalKB)
        if errors > 0 then
            msg = msg .. format("  |cffffff00(%d skipped)|r", errors)
        end
        print(P .. msg)
    end
    return true
end

----------------------------------------------------------------
-- Restore
----------------------------------------------------------------
local function DoRestore()
    if not HasBackup() then
        print(P.."|cffff0000No backup exists|r")
        return false
    end

    local db = WA_SafeGuardDB

    -- rebuild WeakAurasSaved
    local restored = { displays = {} }

    -- restore meta fields
    if type(db.meta) == "table" then
        for k, s in pairs(db.meta) do
            local wrapper = Deserialize(s)
            if wrapper then
                restored[k] = wrapper[1]  -- unwrap {v} → v
            end
        end
    end

    -- restore each aura
    local count = 0
    local errors = 0
    for name, s in pairs(db.displays) do
        local aura = Deserialize(s)
        if aura then
            restored.displays[name] = aura
            count = count + 1
        else
            errors = errors + 1
        end
    end

    if count == 0 then
        print(P.."|cffff0000All auras failed to deserialize|r")
        return false
    end

    WeakAurasSaved = restored

    local msg = format("|cff00ff00RESTORED %d auras!|r", count)
    if errors > 0 then
        msg = msg .. format("  |cffffff00(%d failed)|r", errors)
    end
    print(P .. msg)
    print(P .. "|cffffff00Type /reload now!|r")
    return true
end

----------------------------------------------------------------
-- Status
----------------------------------------------------------------
local function ShowStatus()
    print(P .. "=== Status ===")
    if IsBroken() then
        print(P .. "WeakAuras: |cffff0000CORRUPTED / EMPTY|r")
    else
        print(P .. format("WeakAuras: |cff00ff00OK|r (%d auras)", NumAuras()))
    end
    if HasBackup() then
        local totalKB = 0
        for _, s in pairs(WA_SafeGuardDB.displays) do totalKB = totalKB + #s end
        totalKB = math.floor(totalKB / 1024)
        local ago = math.floor((time() - (WA_SafeGuardDB.t or 0)) / 60)
        print(P .. format("Backup: |cff00ff00OK|r  %d auras  ~%dKB  %d min ago",
            WA_SafeGuardDB.n or 0, totalKB, ago))
    else
        print(P .. "Backup: |cffff0000NONE|r")
    end
end

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------
local frame = CreateFrame("Frame")
local booted = false

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" and not booted then
        booted = true
        local wait = CreateFrame("Frame")
        local el = 0
        wait:SetScript("OnUpdate", function(self2, dt)
            el = el + dt
            if el < 3 then return end
            self2:SetScript("OnUpdate", nil)

            if IsBroken() then
                print(P .. "|cffff4400== WeakAuras is CORRUPTED! ==|r")
                if HasBackup() then
                    DoRestore()
                else
                    print(P .. "|cffff0000No backup yet.|r")
                    print(P .. "Reimport your auras, then /reload")
                end
            else
                DoBackup()
            end
        end)

    elseif event == "PLAYER_LOGOUT" then
        if not IsBroken() then
            pcall(DoBackup, true)
        end
    end
end)

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------
SLASH_WASG1  = "/wasave"
SLASH_WASG2  = "/wabackup"
SlashCmdList.WASG = function() DoBackup() end

SLASH_WASGR1 = "/warestore"
SlashCmdList.WASGR = function() DoRestore() end

SLASH_WASGS1 = "/wastatus"
SlashCmdList.WASGS = function() ShowStatus() end

print(P .. "Loaded. Commands: /wastatus /wasave /warestore")