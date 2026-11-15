-- Rewrites verbose spell power / healing equip lines on item tooltips into short stat lines.
local ADDON, ESF = ...

local enabled = false

-- Print equip lines about spells/healing that no pattern handles.
local DEBUG_UNMATCHED = false

local SCHOOLS = { Arcane = true, Fire = true, Frost = true, Holy = true, Nature = true, Shadow = true }

-- Body of an "Equip:" / "(n) Set:" line -> spellPower, healing, school (any may be nil).
-- Anchored templates; only wording that is certain is listed here.
local function Parse(body)
    local v = strmatch(body, "^Increases damage and healing done by magical spells and effects by up to (%d+)%.$")
    if v then return v, v end

    v = strmatch(body, "^Increases healing done by spells and effects by up to (%d+)%.$")
    if v then return nil, v end

    local heal, dmg = strmatch(body, "^Increases healing done by up to (%d+) and damage done by up to (%d+) for all magical spells and effects%.$")
    if heal then return dmg, heal end

    local school
    school, v = strmatch(body, "^Increases damage done by (%a+) spells and effects by up to (%d+)%.$")
    if school and SCHOOLS[school] then return v, nil, school end
end

-- Full line in, short line(s) out (spell damage first, healing second), or nil if not handled.
local function Rewrite(text)
    local prefix, body = "", strmatch(text, "^Equip: (.+)$")
    if not body then
        prefix, body = strmatch(text, "^(%(%d+%) Set: )(.+)$")
        if not body then return end
    end
    local sp, heal, school = Parse(body)
    if not (sp or heal) then return end
    local out = {}
    if sp then out[#out + 1] = prefix .. "+" .. sp .. " " .. (school and school .. " " or "") .. "Spell Damage" end
    if heal then out[#out + 1] = prefix .. "+" .. heal .. " Spell Healing" end
    return table.concat(out, "\n")   -- two stats -> two lines in the same FontString
end

local reported = {}   -- unmatched lines already printed

local function ReportUnmatched(text)
    if reported[text] or not (strfind(text, "^Equip:") or strfind(text, "^%(%d+%) Set:")) then return end
    local lower = strlower(text)
    if strfind(lower, "spell", 1, true) or strfind(lower, "healing", 1, true) then
        reported[text] = true
        print("|cff33ff99ESF|r unmatched tooltip line: " .. text)
    end
end

local function OnItemTooltip(tooltip)
    if not enabled then return end   -- hooks can't be removed, so the flag is checked here
    local name = tooltip.GetName and tooltip:GetName()
    if not name then return end

    local changed = false
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and not (issecretvalue and issecretvalue(text)) then
            local new = Rewrite(text)
            if new then
                fs:SetText(new)   -- keeps the line's color (equip green)
                changed = true
            elseif DEBUG_UNMATCHED then
                ReportUnmatched(text)
            end
        end
    end
    -- lines changed size: let the tooltip recalculate width and height
    if changed then tooltip:Show() end
end

if TooltipDataProcessor and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

ESF:Module({
    name = "Spell Power Tooltip", key = "spellPowerTooltip",
    desc = "Short spell damage and healing lines on item tooltips",
    note = "Item tooltips show spell damage and healing as short stat lines.",
    tooltip = 'Shows e.g. "+30 Spell Damage" and "+30 Spell Healing" instead of the long "Equip: Increases ..." text.',
    -- the patterns only match the English tooltip text
    unavailable = function()
        return strsub(ESF:GetLocale(), 1, 2) ~= "en" and "English client only" or nil
    end,
    onChange = function(on) enabled = on end,
})
