local ADDON, ESF = ...   -- the same ESF table is shared by all files of the addon

ESF.features = {}   -- flat list, used for defaults/init
ESF.sections = {}   -- ordered list of { name, features }
local sectionByName = {}

local function GetSection(name)
    local s = sectionByName[name]
    if not s then
        s = { name = name, features = {} }
        sectionByName[name] = s
        table.insert(ESF.sections, s)
    end
    return s
end

-- section: caption shown in the panel (features with the same caption are grouped)
-- extra (optional): function(checkbox, panel) -> widget, placed indented under the checkbox
-- Returns the feature table; set f.perChar = true to store its value in ESFCharDB.
function ESF:RegisterFeature(section, key, label, default, onToggle, extra)
    local s = GetSection(section)
    local f = { key = key, label = label, default = default, onToggle = onToggle, extra = extra }
    table.insert(s.features, f)
    table.insert(self.features, f)
    return f
end

-- Feature without a checkbox: build(panel) -> widget, placed in the column.
-- onChange(value) is called once at load with the saved (or default) value;
-- the feature stores later changes in ESFDB[key] itself.
function ESF:RegisterCustomFeature(section, key, default, onChange, build)
    local f = self:RegisterFeature(section, key, nil, default, onChange)
    f.custom = build
    return f
end

-- Small grey text shown next to a section caption.
function ESF:SetSectionNote(section, note)
    GetSection(section).note = note
end

-- Saved-variables table a feature's value lives in.
function ESF:Store(f)
    return f.perChar and ESFCharDB or ESFDB
end

local INDENT = 26

local function BuildPanel()
    local panel = CreateFrame("Frame")
    panel.name = "ExtraSausage"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ExtraSausage")

    -- prev = last placed widget, prevX = its left offset relative to the column
    local prev, prevX = title, 0
    local function Place(widget, x, gap)
        widget:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", x - prevX, -gap)
        prev, prevX = widget, x
    end

    for _, s in ipairs(ESF.sections) do
        local caption = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
        caption:SetText(s.name)
        Place(caption, 0, (prev == title) and 16 or 24)
        if s.note then
            local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            note:SetPoint("BOTTOMLEFT", caption, "BOTTOMRIGHT", 8, 1)
            note:SetText(s.note)
        end

        for _, f in ipairs(s.features) do
            if f.custom then
                local w = f.custom(panel)
                if w then Place(w, 0, 6) end
            else
                local db = ESF:Store(f)
                local cb = CreateFrame("CheckButton", "ESFCheck" .. f.key, panel, "InterfaceOptionsCheckButtonTemplate")
                Place(cb, 0, 6)
                _G[cb:GetName() .. "Text"]:SetText(f.label)
                cb:SetChecked(db[f.key])
                cb:SetScript("OnClick", function(self)
                    db[f.key] = self:GetChecked() and true or false
                    f.onToggle(db[f.key])
                end)

                if f.extra then
                    local w = f.extra(cb, panel)
                    if w then Place(w, INDENT, 2) end
                end
            end
        end
    end

    if Settings and Settings.RegisterCanvasLayoutCategory then
        ESF.category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(ESF.category)
    else
        InterfaceOptions_AddCategory(panel)
    end
    ESF.panel = panel
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    ESFDB = ESFDB or {}
    ESFCharDB = ESFCharDB or {}
    for _, f in ipairs(ESF.features) do
        local db = ESF:Store(f)
        if db[f.key] == nil then db[f.key] = f.default end
        f.onToggle(db[f.key])
    end
    BuildPanel()
end)

-- Sub-commands: ESF.commands.name = function(rest) ... end  ->  /esf name rest
ESF.commands = {}

SLASH_ESF1 = "/esf"
SlashCmdList.ESF = function(msg)
    local cmd, rest = strmatch(msg or "", "^%s*(%S+)%s*(.-)%s*$")
    if cmd then
        local fn = ESF.commands[strlower(cmd)]
        if fn then
            fn(rest)
        else
            print("ESF: unknown command '" .. cmd .. "'")
        end
        return
    end
    if ESF.category then
        Settings.OpenToCategory(ESF.category:GetID())
    else
        InterfaceOptionsFrame_OpenToCategory(ESF.panel)
        InterfaceOptionsFrame_OpenToCategory(ESF.panel) -- called twice, known Blizzard quirk
    end
end
