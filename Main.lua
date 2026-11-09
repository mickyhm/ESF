local ADDON, ESF = ...   -- the same ESF table is shared by all files of the addon

ESF.features = {}   -- flat list, used for defaults/init
ESF.sections = {}   -- ordered list of { name, features }
local sectionByName = {}

-- section: caption shown in the panel (features with the same caption are grouped)
-- extra (optional): function(checkbox, panel) -> widget, placed indented under the checkbox
function ESF:RegisterFeature(section, key, label, default, onToggle, extra)
    local s = sectionByName[section]
    if not s then
        s = { name = section, features = {} }
        sectionByName[section] = s
        table.insert(self.sections, s)
    end
    local f = { key = key, label = label, default = default, onToggle = onToggle, extra = extra }
    table.insert(s.features, f)
    table.insert(self.features, f)
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

        for _, f in ipairs(s.features) do
            local cb = CreateFrame("CheckButton", "ESFCheck" .. f.key, panel, "InterfaceOptionsCheckButtonTemplate")
            Place(cb, 0, 6)
            _G[cb:GetName() .. "Text"]:SetText(f.label)
            cb:SetChecked(ESFDB[f.key])
            cb:SetScript("OnClick", function(self)
                ESFDB[f.key] = self:GetChecked() and true or false
                f.onToggle(ESFDB[f.key])
            end)

            if f.extra then
                local w = f.extra(cb, panel)
                if w then Place(w, INDENT, 2) end
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
    for _, f in ipairs(ESF.features) do
        if ESFDB[f.key] == nil then ESFDB[f.key] = f.default end
        f.onToggle(ESFDB[f.key])
    end
    BuildPanel()
end)

SLASH_ESF1 = "/esf"
SlashCmdList.ESF = function()
    if ESF.category then
        Settings.OpenToCategory(ESF.category:GetID())
    else
        InterfaceOptionsFrame_OpenToCategory(ESF.panel)
        InterfaceOptionsFrame_OpenToCategory(ESF.panel) -- called twice, known Blizzard quirk
    end
end