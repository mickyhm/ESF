-- Features\BagOrder.lua
-- New items at the bottom: the game puts new items into the last bag first
-- (C_Container.SetInsertItemsLeftToRight), and inside every bag the slots are shown in reverse
-- (first slot where the last one is, and so on). Bag order and the items themselves don't change;
-- only the buttons are drawn at swapped positions. Works in separate and combined bag view.
local ADDON, ESF = ...

local enabled = false
local loaded = false
local FIRST_BAG = 0
local LAST_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5   -- backpack .. reagent bag

local frames = {}        -- container frames we handle
local waiting = false    -- an update is waiting for combat to end

local function BagOf(button)
    if button.GetBagID then return button:GetBagID() end
    local parent = button:GetParent()
    return parent and parent:GetID()
end

-- Item buttons of a container frame (modern and old style frames).
local function Buttons(frame)
    local list = {}
    if frame.EnumerateValidItems then
        for _, b in frame:EnumerateValidItems() do list[#list + 1] = b end
    else
        local name = frame:GetName()
        for i = 1, frame.size or 0 do
            local b = name and _G[name .. "Item" .. i]
            if b then list[#list + 1] = b end
        end
    end
    return list
end

local function Blocked(list)
    if not InCombatLockdown() then return false end
    for _, b in ipairs(list) do
        if b:IsProtected() then return true end
    end
    return false
end

local function Round(v) return math.floor(v + 0.5) end

-- Lay out the buttons of each bag in this frame. A bag always uses the same set of positions,
-- whether swapped or not; sorted in reading order (top to bottom, left to right) they are the
-- positions of slot 1..n in Blizzard's layout. Swapped, slot s gets position n - s + 1.
-- This works from any current state, so it can safely run as often as needed.
local function Arrange(frame)
    if not frame:IsShown() then return end
    if not enabled and not frame.esfTouched then return end   -- off: leave Blizzard's layout alone
    local list = Buttons(frame)
    if Blocked(list) then waiting = true return end
    local fl, ft = frame:GetLeft(), frame:GetTop()
    if not (fl and ft) then return end

    local byBag = {}   -- bag -> { button, ... }
    for _, b in ipairs(list) do
        local bag = BagOf(b)
        if bag and bag >= FIRST_BAG and bag <= LAST_BAG then
            local l, t = b:GetLeft(), b:GetTop()
            if not (l and t) then return end   -- not laid out yet; a later update tries again
            b.esfPos = { l - fl, t - ft }
            byBag[bag] = byBag[bag] or {}
            table.insert(byBag[bag], b)
        end
    end

    for _, buttons in pairs(byBag) do
        local positions = {}
        for i, b in ipairs(buttons) do positions[i] = b.esfPos end
        table.sort(positions, function(a, c)
            local ya, yc = Round(a[2]), Round(c[2])
            if ya ~= yc then return ya > yc end   -- higher row first
            return a[1] < c[1]
        end)
        table.sort(buttons, function(a, c) return a:GetID() < c:GetID() end)
        local n = #buttons
        for i, b in ipairs(buttons) do
            local pos = positions[enabled and (n - i + 1) or i]
            local cur = b.esfPos
            if math.abs(cur[1] - pos[1]) > 0.5 or math.abs(cur[2] - pos[2]) > 0.5 then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", frame, "TOPLEFT", pos[1], pos[2])
            end
        end
    end
    frame.esfTouched = enabled
end

local function ArrangeAll()
    for frame in pairs(frames) do Arrange(frame) end
end

local function ArrangeSoon(frame)
    C_Timer.After(0, function() Arrange(frame) end)
end

local function OnLayout(frame)
    if not frame or not frames[frame] then return end
    Arrange(frame)
    ArrangeSoon(frame)   -- again once Blizzard is completely done
end

local function HookFrame(frame)
    if not frame or frames[frame] then return end
    frames[frame] = true
    if frame.UpdateItemLayout then
        hooksecurefunc(frame, "UpdateItemLayout", OnLayout)
    end
    frame:HookScript("OnShow", ArrangeSoon)
end

HookFrame(ContainerFrameCombinedBags)
for i = 1, NUM_CONTAINER_FRAMES or 13 do HookFrame(_G["ContainerFrame" .. i]) end
if ContainerFrame_GenerateFrame then   -- old style frames are laid out here
    hooksecurefunc("ContainerFrame_GenerateFrame", OnLayout)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if not waiting then return end
        waiting = false
    end
    C_Timer.After(0, ArrangeAll)
end)

local function SetInsert(on)
    if C_Container and C_Container.SetInsertItemsLeftToRight then
        C_Container.SetInsertItemsLeftToRight(on)
    end
end

ESF:Section("Bag Order")

ESF:Checkbox({
    key = "newItemsBottom", label = "New Items at the Bottom", default = false,
    tooltip = "New items go into your last bag first, and the slots inside every bag are shown in reverse, so new items appear at the bottom.",
    onChange = function(on)
        -- at login only switch the game setting on; an unchecked box leaves it as it is
        if on or loaded then SetInsert(on) end
        enabled = on
        ArrangeAll()
        loaded = true
    end,
})
