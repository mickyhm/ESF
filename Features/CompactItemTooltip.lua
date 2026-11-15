-- Rewrites verbose stat effects on item tooltips into short stat lines and puts them, in a fixed
-- order, ahead of the other effects (Equip, Use, Chance on hit).
local ADDON, ESF = ...

local active = false   -- module on and available
local settingOn = {}   -- checkbox key -> value

-- Print effect lines that no pattern handles.
local DEBUG_UNMATCHED = false

----------------------------------------------------------------------
-- Checkboxes, in menu order
----------------------------------------------------------------------
local SETTINGS = {
    { key = "attackPower",       group = "Melee and Ranged", label = "Attack Power" },
    { key = "rangedAttackPower", group = "Melee and Ranged", label = "Ranged Attack Power" },
    { key = "hit",               group = "Melee and Ranged", label = "Hit Chance" },
    { key = "crit",              group = "Melee and Ranged", label = "Crit Chance" },
    { key = "spellPower",        group = "Spell",            label = "Spell Damage and Healing",
      tooltip = "Also covers damage of a single school, e.g. +15 Fire Spell Damage." },
    { key = "spellHit",          group = "Spell",            label = "Spell Hit Chance" },
    { key = "spellCrit",         group = "Spell",            label = "Spell Crit Chance" },
    { key = "mp5",               group = "Spell",            label = "Mana per 5 Sec." },
    { key = "defense",           group = "Defenses",         label = "Defense" },
    { key = "dodge",             group = "Defenses",         label = "Dodge Chance" },
    { key = "parry",             group = "Defenses",         label = "Parry Chance" },
    { key = "blockChance",       group = "Defenses",         label = "Block Chance" },
    { key = "blockValue",        group = "Defenses",         label = "Block Value" },
}

----------------------------------------------------------------------
-- Stats, in display order on the tooltip
----------------------------------------------------------------------
local STATS = {
    { key = "attackPower",       setting = "attackPower",       suffix = " Attack Power" },
    { key = "rangedAttackPower", setting = "rangedAttackPower", suffix = " Ranged Attack Power" },
    { key = "hit",               setting = "hit",               suffix = "% Hit Chance" },
    { key = "crit",              setting = "crit",              suffix = "% Crit Chance" },
    { key = "spellDamage",       setting = "spellPower",        suffix = " Spell Damage" },
    { key = "spellHealing",      setting = "spellPower",        suffix = " Spell Healing" },
    { key = "spellHit",          setting = "spellHit",          suffix = "% Spell Hit Chance" },
    { key = "spellCrit",         setting = "spellCrit",         suffix = "% Spell Crit Chance" },
    { key = "mp5",               setting = "mp5",               suffix = " Mana per 5 sec." },
    { key = "defense",           setting = "defense",           suffix = " Defense" },
    { key = "dodge",             setting = "dodge",             suffix = "% Dodge Chance" },
    { key = "parry",             setting = "parry",             suffix = "% Parry Chance" },
    { key = "blockChance",       setting = "blockChance",       suffix = "% Block Chance" },
    { key = "blockValue",        setting = "blockValue",        suffix = " Block Value" },
}
local statByKey = {}
for i, s in ipairs(STATS) do
    s.order = i
    statByKey[s.key] = s
end

local SCHOOLS = { Arcane = true, Fire = true, Frost = true, Holy = true, Nature = true, Shadow = true }

-- Effect text (without "Equip: " / "(n) Set: ") -> list of { stat, value [, school] }.
-- Anchored templates; only wording known from the English client is listed here.
local RULES = {
    { "^%+(%d+) Attack Power%.$", function(v) return { { "attackPower", v } } end },
    { "^%+(%d+) ranged Attack Power%.$", function(v) return { { "rangedAttackPower", v } } end },
    { "^Improves your chance to hit by (%d+)%%%.$", function(v) return { { "hit", v } } end },
    { "^Improves your chance to get a critical strike by (%d+)%%%.$", function(v) return { { "crit", v } } end },
    { "^Increases damage and healing done by magical spells and effects by up to (%d+)%.$",
        function(v) return { { "spellDamage", v }, { "spellHealing", v } } end },
    { "^Increases healing done by up to (%d+) and damage done by up to (%d+) for all magical spells and effects%.$",
        function(heal, dmg) return { { "spellDamage", dmg }, { "spellHealing", heal } } end },
    { "^Increases damage done by magical spells and effects by up to (%d+)%.$",
        function(v) return { { "spellDamage", v } } end },
    { "^Increases damage done by (%a+) spells and effects by up to (%d+)%.$",
        function(school, v) if SCHOOLS[school] then return { { "spellDamage", v, school } } end end },
    { "^Increases healing done by spells and effects by up to (%d+)%.$", function(v) return { { "spellHealing", v } } end },
    { "^Improves your chance to hit with spells by (%d+)%%%.$", function(v) return { { "spellHit", v } } end },
    { "^Improves your chance to get a critical strike with spells by (%d+)%%%.$", function(v) return { { "spellCrit", v } } end },
    { "^Restores (%d+) mana per 5 sec%.$", function(v) return { { "mp5", v } } end },
    { "^Increased Defense %+(%d+)%.$", function(v) return { { "defense", v } } end },
    { "^Increases your chance to dodge an attack by (%d+)%%%.$", function(v) return { { "dodge", v } } end },
    { "^Increases your chance to parry an attack by (%d+)%%%.$", function(v) return { { "parry", v } } end },
    { "^Increases your chance to block attacks with a shield by (%d+)%%%.$", function(v) return { { "blockChance", v } } end },
    { "^Increases the block value of your shield by (%d+)%.$", function(v) return { { "blockValue", v } } end },
}

-- Short entries for an effect, or nil if it isn't handled or its checkbox is off.
local function Parse(body)
    for _, r in ipairs(RULES) do
        local a, b = strmatch(body, r[1])
        if a then
            local list = r[2](a, b)
            if not list then return end
            local entries = {}
            for _, e in ipairs(list) do
                local stat = statByKey[e[1]]
                if not settingOn[stat.setting] then return end
                local name = e[3] and (" " .. e[3] .. stat.suffix) or stat.suffix
                -- single-school damage sorts right after general spell damage
                entries[#entries + 1] = { order = stat.order + (e[3] and 0.5 or 0), text = "+" .. e[2] .. name }
            end
            return entries
        end
    end
end

local function SortEntries(entries)
    for i, e in ipairs(entries) do e.index = i end
    table.sort(entries, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.index < b.index
    end)
end

----------------------------------------------------------------------
-- Tooltip
----------------------------------------------------------------------
local reported = {}

local function ReportUnmatched(text)
    if not reported[text] then
        reported[text] = true
        print("|cff33ff99ESF|r unmatched tooltip line: " .. text)
    end
end

local function IsEffect(text)
    return strfind(text, "^Equip: ") or strfind(text, "^Use: ") or strfind(text, "^Chance on hit: ")
end

local written = setmetatable({}, { __mode = "k" })   -- FontString -> text we set on it

local function OnItemTooltip(tooltip)
    if not active then return end   -- hooks can't be removed, so the state is checked here
    local name = tooltip.GetName and tooltip:GetName()
    if not name then return end

    local lines = {}
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and issecretvalue and issecretvalue(text) then return end
        if text and written[fs] == text then return end   -- this tooltip is already rewritten
        lines[i] = { fs = fs, text = text }
    end

    local changed = false

    -- the effect block: the first run of Equip / Use / Chance on hit lines
    local first, last
    for i, l in ipairs(lines) do
        if l.text and IsEffect(l.text) then
            first = first or i
            last = i
        elseif first then
            break
        end
    end

    if first then
        local shorts, slots, others = {}, 0, {}
        for i = first, last do
            local l = lines[i]
            local body = strmatch(l.text, "^Equip: (.+)$")
            local entries = body and Parse(body)
            if entries then
                slots = slots + 1
                for _, e in ipairs(entries) do shorts[#shorts + 1] = e end
                l.isShort = true
            else
                if DEBUG_UNMATCHED and body then ReportUnmatched(l.text) end
                others[#others + 1] = l
            end
        end

        if slots > 0 then
            SortEntries(shorts)
            -- short lines keep the color of the first shortened line (equip green)
            local r, g, b
            for i = first, last do
                if lines[i].isShort then r, g, b = lines[i].fs:GetTextColor() break end
            end
            local otherColors = {}
            for k, l in ipairs(others) do otherColors[k] = { l.fs:GetTextColor() } end

            -- one entry per slot, the last short slot takes whatever is left
            local texts = {}
            for k = 1, slots do
                if k < slots then
                    texts[k] = shorts[k].text
                else
                    local rest = {}
                    for j = slots, #shorts do rest[#rest + 1] = shorts[j].text end
                    texts[k] = table.concat(rest, "\n")
                end
            end

            local slot = first
            for k = 1, slots do
                local fs = lines[slot].fs
                fs:SetText(texts[k])
                fs:SetTextColor(r, g, b)
                written[fs] = texts[k]
                slot = slot + 1
            end
            for k, l in ipairs(others) do
                local fs = lines[slot].fs
                fs:SetText(l.text)
                fs:SetTextColor(unpack(otherColors[k]))
                slot = slot + 1
            end
            changed = true
        end
    end

    -- set bonuses stay in the set section and are shortened in place
    for _, l in ipairs(lines) do
        local prefix, body
        if l.text then prefix, body = strmatch(l.text, "^(%(%d+%) Set: )(.+)$") end
        if body then
            local entries = Parse(body)
            if entries then
                SortEntries(entries)
                local out = {}
                for _, e in ipairs(entries) do out[#out + 1] = prefix .. e.text end
                local text = table.concat(out, "\n")
                l.fs:SetText(text)
                written[l.fs] = text
                changed = true
            elseif DEBUG_UNMATCHED then
                ReportUnmatched(l.text)
            end
        end
    end

    -- lines changed size: let the tooltip recalculate width and height
    if changed then tooltip:Show() end
end

if TooltipDataProcessor and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
-- carry over the on/off state saved under the old key
table.insert(ESF.onLoad, function()
    if ESFDB.compactItemTooltip == nil and ESFDB.spellPowerTooltip ~= nil then
        ESFDB.compactItemTooltip = ESFDB.spellPowerTooltip
    end
    ESFDB.spellPowerTooltip = nil
end)

local mod
mod = ESF:Module({
    name = "Compact Item Tooltip", key = "compactItemTooltip",
    desc = "Shorter item tooltips for many effects",
    note = "Rewrites long item effects into short lines, like +10 Spell Damage.",
    -- the patterns only match the English tooltip text
    unavailable = function()
        return strsub(ESF:GetLocale(), 1, 2) ~= "en" and "English client only" or nil
    end,
    onChange = function() active = mod:IsOn() end,
})

for _, s in ipairs(SETTINGS) do
    ESF:Section(s.group)
    ESF:Checkbox({
        key = "compactTooltip_" .. s.key, label = s.label, default = true, tooltip = s.tooltip,
        onChange = function(on) settingOn[s.key] = on end,
    })
end
