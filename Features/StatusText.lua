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

-- Only these bars are affected. Add more frames/groups here later.
local groups = {
    player = {
        Get(PlayerFrame, "PlayerFrameContent", "PlayerFrameContentMain", "HealthBarsContainer", "HealthBar"),
        Get(PlayerFrame, "PlayerFrameContent", "PlayerFrameContentMain", "ManaBarArea", "ManaBar"),
    },
    target = {
        Get(TargetFrame, "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar"),
        Get(TargetFrame, "TargetFrameContent", "TargetFrameContentMain", "ManaBar"),
    },
}

local enabled = { player = false, target = false }
local texts = {}    -- bar -> our FontString
local groupOf = {}  -- bar -> "player" / "target"

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
    -- pcall: GetValue may return a restricted value on this client
    local ok = pcall(function() fs:SetText(BreakUpLargeNumbers(bar:GetValue())) end)
    if ok then
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
ev:SetScript("OnEvent", function()
    for name in pairs(groups) do RefreshGroup(name) end
end)

ESF:RegisterFeature("Status Text", "statusTextPlayer", "Current Value Only (Player Frame)", true, function(on)
    enabled.player = on
    RefreshGroup("player")
end)

ESF:RegisterFeature("Status Text", "statusTextTarget", "Current Value Only (Target Frame)", true, function(on)
    enabled.target = on
    RefreshGroup("target")
end)