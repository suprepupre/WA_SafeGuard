WA_SafeGuardDB = WA_SafeGuardDB or {}

local P = "|cff00ccff[SafeGuard]|r "

----------------------------------------------------------------
-- LibCompress (optional, ships with WeakAuras)
----------------------------------------------------------------
local LC, LCE

local function InitLC()
    if LC then return true end
    local ok = pcall(function()
        LC  = LibStub("LibCompress")
        LCE = LC:GetAddonEncodeTable()
    end)
    if not ok then LC = nil; LCE = nil end
    return LC ~= nil
end

----------------------------------------------------------------
-- Serializer: handles functions, cycles, NaN, Inf
----------------------------------------------------------------
local B, N

local function w(v, seen)
    local t = type(v)

    if t == "table" then
        -- circular reference guard
        if seen[v] then
            N=N+1; B[N]="nil"
            return
        end
        seen[v] = true

        N=N+1; B[N]="{"
        for k, val in pairs(v) do
            local kt = type(k)
            local vt = type(val)

            -- skip keys that aren't serializable
            if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
                -- skip this pair entirely
            -- skip values that aren't serializable
            elseif vt == "function" or vt == "userdata" or vt == "thread" then
                -- skip this pair entirely
            else
                N=N+1; B[N]="["
                w(k, seen)
                N=N+1; B[N]="]="
                w(val, seen)
                N=N+1; B[N]=","
            end
        end
        N=N+1; B[N]="}"

        -- allow same table from different paths (diamond pattern)
        -- but block actual cycles (ancestor revisit)
        seen[v] = nil

    elseif t == "string" then
        N=N+1; B[N]=string.format("%q", v)

    elseif t == "number" then
        -- handle special float values
        if v ~= v then              -- NaN
            N=N+1; B[N]="0"
        elseif v == 1/0 then        -- +Infinity
            N=N+1; B[N]="1e308"
        elseif v == -1/0 then       -- -Infinity
            N=N+1; B[N]="-1e308"
        else
            N=N+1; B[N]=tostring(v)
        end

    elseif t == "boolean" then
        N=N+1; B[N] = v and "true" or "false"

    else
        N=N+1; B[N]="nil"
    end
end

local function Serialize(tbl)
    B = {}; N = 0
    w(tbl, {})
    local r = table.concat(B)
    B = nil
    return r
end

local function Deserialize(s)
    if not s or #s < 2 then return nil end
    local fn = loadstring("return " .. s)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, r = pcall(fn)
    return ok and type(r) == "table" and r or nil
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
    if type(t) ~= "table" or type(t.displays) ~= "table" then return 0 end
    local c = 0
    for _ in pairs(t.displays) do c = c + 1 end
    return c
end

local function HasBackup()
    return type(WA_SafeGuardDB) == "table"
        and type(WA_SafeGuardDB.data) == "string"
        and #WA_SafeGuardDB.data > 50
end

-- Strip caches that WeakAuras regenerates on load
local function CleanCopy()
    local copy = {}
    for k, v in pairs(WeakAurasSaved) do
        if k ~= "registered"
           and k ~= "tempIconCache"
           and k ~= "iconCache"
           and k ~= "loaded"
           and k ~= "newFeaturesSeen" then
            copy[k] = v
        end
    end
    return copy
end

----------------------------------------------------------------
-- Backup
----------------------------------------------------------------
local function DoBackup(silent)
    if IsBroken() then
        if not silent then print(P .. "|cffff0000WA data broken, cannot backup|r") end
        return false
    end

    local ok, raw = pcall(Serialize, CleanCopy())
    if not ok then
        if not silent then
            print(P .. "|cffff0000Serialize error:|r " .. tostring(raw))
        end
        return false
    end
    if not raw or #raw < 10 then
        if not silent then print(P .. "|cffff0000Serialize returned empty|r") end
        return false
    end

    local rawKB = math.floor(#raw / 1024)
    local stored = raw
    local compressed = false

    if InitLC() then
        local cOk, comp = pcall(LC.CompressHuffman, LC, raw)
        if cOk and comp then
            local eOk, enc = pcall(LCE.Encode, LCE, comp)
            if eOk and enc and #enc < #raw then
                stored = enc
                compressed = true
            end
        end
    end

    WA_SafeGuardDB = {
        data = stored,
        z    = compressed,
        n    = NumAuras(),
        t    = time(),
    }

    if not silent then
        local stKB = math.floor(#stored / 1024)
        if compressed then
            print(P .. format("|cff00ff00Backup OK|r  %d auras  %dKB -> %dKB (%.0f%% smaller)",
                NumAuras(), rawKB, stKB, (1 - #stored / #raw) * 100))
        else
            print(P .. format("|cff00ff00Backup OK|r  %d auras  %dKB",
                NumAuras(), rawKB))
        end
    end
    return true
end

----------------------------------------------------------------
-- Restore
----------------------------------------------------------------
local function DoRestore()
    if not HasBackup() then
        print(P .. "|cffff0000No backup exists|r")
        return false
    end

    local raw
    if WA_SafeGuardDB.z then
        if not InitLC() then
            print(P .. "|cffff0000Need LibCompress to decompress|r")
            return false
        end
        local dOk, decoded = pcall(LCE.Decode, LCE, WA_SafeGuardDB.data)
        if dOk and decoded then
            local uOk, unpacked = pcall(LC.Decompress, LC, decoded)
            if uOk then raw = unpacked end
        end
        if not raw then
            print(P .. "|cffff0000Decompression failed|r")
            return false
        end
    else
        raw = WA_SafeGuardDB.data
    end

    local data = Deserialize(raw)
    if not data or type(data.displays) ~= "table" then
        print(P .. "|cffff0000Backup data invalid after deserialize|r")
        return false
    end

    local c = 0
    for _ in pairs(data.displays) do c = c + 1 end

    WeakAurasSaved = data
    print(P .. format("|cff00ff00RESTORED %d auras!|r", c))
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
        local kb = math.floor(#WA_SafeGuardDB.data / 1024)
        local ago = math.floor((time() - (WA_SafeGuardDB.t or 0)) / 60)
        print(P .. format("Backup: |cff00ff00OK|r  %d auras  %dKB  %d min ago  compressed=%s",
            WA_SafeGuardDB.n or 0, kb, ago,
            WA_SafeGuardDB.z and "yes" or "no"))
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