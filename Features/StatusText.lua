-- Features\StatusText.lua
local ADDON, ESF = ...

-- Walk a chain of keys, return nil if any step is missing.
local function Get(root, ...)
    local obj = root
    for i = 1, select("#", ...) do
        if type(obj) ~= "table" then return nil end
        obj = obj[select(i, ...)]
    end
    return obj
end

-- Bars per group. Missing frames (different client layouts) are skipped.
local groups = { player = {}, target = {}, pet = {}, party = {} }

local function Add(name, bar)
    if type(bar) == "table" and bar.GetValue then table.insert(groups[name], bar) end
end

Add("player", Get(PlayerFrame, "PlayerFrameContent", "PlayerFrameContentMain", "HealthBarsContainer", "HealthBar"))
Add("player", Get(PlayerFrame, "PlayerFrameContent", "PlayerFrameContentMain", "ManaBarArea", "ManaBar"))
Add("target", Get(TargetFrame, "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar"))
Add("target", Get(TargetFrame, "TargetFrameContent", "TargetFrameContentMain", "ManaBar"))
Add("pet", PetFrameHealthBar or Get(PetFrame, "healthbar"))
Add("pet", PetFrameManaBar or Get(PetFrame, "manabar"))

-- Party frames (raid-style ones have Blizzard's own "Health Remaining" option): new layout first, old globals as fallback.
for i = 1, 4 do
    local m = Get(PartyFrame, "MemberFrame" .. i)
    if m then
        Add("party", Get(m, "HealthBarContainer", "HealthBar") or m.HealthBar)
        Add("party", m.ManaBar)
    else
        Add("party", _G["PartyMemberFrame" .. i .. "HealthBar"])
        Add("party", _G["PartyMemberFrame" .. i .. "ManaBar"])
    end
end

local enabled = { player = false, target = false, pet = false, party = false }
local texts = {}    -- bar -> our FontString
local groupOf = {}  -- bar -> group name

-- Values can be secret on this client: formatting (Lua math) then fails,
-- but a secret value can still be displayed as is.
local function SetValueText(fs, v)
    if pcall(function() fs:SetText(BreakUpLargeNumbers(v)) end) then return true end
    return pcall(fs.SetText, fs, v)
end

-- Blizzard's own text objects on a bar (center text, and left/right used for percent/both)
local function SetBlizzAlpha(bar, a)
    if bar.TextString then bar.TextString:SetAlpha(a) end
    if bar.LeftText then bar.LeftText:SetAlpha(a) end
    if bar.RightText then bar.RightText:SetAlpha(a) end
end

local function Refresh(bar)
    local fs = texts[bar]
    if not fs then return end
    if not enabled[groupOf[bar]] then
        fs:Hide()
        SetBlizzAlpha(bar, 1)
        return
    end
    if SetValueText(fs, bar:GetValue()) then
        fs:Show()
        SetBlizzAlpha(bar, 0)
    else
        fs:Hide()
        SetBlizzAlpha(bar, 1)
    end
end

local function RefreshGroup(name)
    for _, bar in ipairs(groups[name]) do Refresh(bar) end
end

for name, list in pairs(groups) do
    for _, bar in ipairs(list) do
        groupOf[bar] = name

        local src = bar.TextString
        local fs = bar:CreateFontString(nil, "OVERLAY")
        if src then
            fs:SetFont(src:GetFont())
            fs:SetTextColor(src:GetTextColor())
            fs:SetShadowColor(src:GetShadowColor())
            fs:SetShadowOffset(src:GetShadowOffset())
        else
            fs:SetFontObject(TextStatusBarText or GameFontNormalSmall)
        end
        fs:SetPoint("CENTER", bar, "CENTER")
        texts[bar] = fs

        if bar.UpdateTextString then
            hooksecurefunc(bar, "UpdateTextString", function() Refresh(bar) end)
        end
        bar:HookScript("OnValueChanged", function() Refresh(bar) end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UNIT_DISPLAYPOWER")
ev:RegisterEvent("UNIT_PET")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:SetScript("OnEvent", function()
    for name in pairs(groups) do
        for _, bar in ipairs(groups[name]) do Refresh(bar) end
    end
end)

local function Register(name, key, label)
    ESF:RegisterFeature("Status Text", key, label, true, function(on)
        enabled[name] = on
        RefreshGroup(name)
    end)
end

Register("player", "statusTextPlayer", "Current Value Only (Player Frame)")
Register("target", "statusTextTarget", "Current Value Only (Target Frame)")
Register("pet", "statusTextPet", "Current Value Only (Pet Frame)")
Register("party", "statusTextParty", "Current Value Only (Party Frames)")
