-- Features\ReagentBag.lua
-- When an action opens all normal bags at once (combined backpack, or several separate bags in
-- the same frame), the reagent bag opens too. It closes again once no normal bag is open.
-- Opening a single bag (backpack only, one bag by click) leaves the reagent bag alone, unless
-- the backpack is the only equipped bag.
local ADDON, ESF = ...

local enabled = false
local REAGENT_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
local FIRST_BAG, LAST_BAG = 0, NUM_BAG_SLOTS or 4   -- backpack + normal bags

local GetNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots

local function Combined()
    return ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown()
end

-- every equipped normal bag is open
local function AllOpen()
    if Combined() then return true end
    for bag = FIRST_BAG, LAST_BAG do
        if (GetNumSlots(bag) or 0) > 0 and not IsBagOpen(bag) then return false end
    end
    return true
end

-- number of equipped normal bags (backpack included)
local function Equipped()
    local n = 0
    for bag = FIRST_BAG, LAST_BAG do
        if (GetNumSlots(bag) or 0) > 0 then n = n + 1 end
    end
    return n
end

local function AnyOpen()
    if Combined() then return true end
    for bag = FIRST_BAG, LAST_BAG do
        if IsBagOpen(bag) then return true end
    end
    return false
end

-- Normal bag windows opened during the current frame. One key press / click opens all its bags
-- in the same frame, so this tells "open all" apart from opening single bags one by one.
local openedNow, combinedNow, pending = 0, false, false

local function Evaluate()
    pending = false
    local opened, combined = openedNow, combinedNow
    openedNow, combinedNow = 0, false
    if not enabled or (GetNumSlots(REAGENT_BAG) or 0) == 0 then return end
    local reagentOpen = IsBagOpen(REAGENT_BAG)
    -- "all at once" = at least two windows, or the only one if just the backpack is equipped
    if (combined or opened >= math.min(2, Equipped())) and AllOpen() then
        if not reagentOpen then OpenBag(REAGENT_BAG) end
    elseif reagentOpen and not AnyOpen() then
        CloseBag(REAGENT_BAG)
    end
end

local function Schedule()
    if not pending then
        pending = true
        C_Timer.After(0, Evaluate)   -- after the whole action is done
    end
end

local function IsNormalBag(frame)
    local id = frame:GetID()
    return id and id >= FIRST_BAG and id <= LAST_BAG
end

local function HookFrame(frame)
    if not frame or frame.esfReagentHooked then return end
    frame.esfReagentHooked = true
    frame:HookScript("OnShow", function(self)
        if frame == ContainerFrameCombinedBags then
            combinedNow = true
        elseif IsNormalBag(self) then
            openedNow = openedNow + 1
        else
            return
        end
        Schedule()
    end)
    frame:HookScript("OnHide", function(self)
        if frame == ContainerFrameCombinedBags or IsNormalBag(self) then Schedule() end
    end)
end

HookFrame(ContainerFrameCombinedBags)
for i = 1, NUM_CONTAINER_FRAMES or 13 do HookFrame(_G["ContainerFrame" .. i]) end

ESF:Section("Reagent Bag")

ESF:Checkbox({
    key = "reagentBagWithAll", label = "Open With All Bags", default = true,
    tooltip = "The reagent bag opens when all your bags are opened at once (e.g. Open All Bags or the combined backpack) and closes with them. Opening a single bag leaves it closed.",
    onChange = function(on) enabled = on end,
})
