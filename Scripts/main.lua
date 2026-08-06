-- Moor_InventoryKeeper: inventory persistence across successful extraction.

local UEHelpers = require("UEHelpers")

local PLAYER_STATE_CLASS = "/Game/TheMound/Blueprints/Game/BP_TMPlayerState.BP_TMPlayerState_C"
local LastRaidInventory = nil
local WasInRaid = false
local RestoreScheduled = false
local RestoreAttempts = 0
local RaidPlayerController = nil
local RaidInventoryComponent = nil
local RestorePlayerController = nil
local RestoreInventoryComponent = nil
local NativeStoreItemPaths = {}
local NativeTreasureItemPaths = {}
local ItemKeepCache = {}
local LastCatalogGameState = nil
local LastCatalogRefreshAt = 0
local NormalizedEquipmentLog = {}

-- Items in Pickups/Other mix real equipment with quest/special objects.  Only
-- these asset-name fragments belong to the requested Tools & Artifacts or
-- Support categories.
local ALLOWED_OTHER_ITEM_MARKERS = {
    "DiviningRod", "Yig", "CurseJar", "Ichor", "Nyarlathotep", "Mask",
    "Crucifix", "Medallion", "SoundBowl", "SlaveFinder",
    "Ammonia", "Map_", "Lantern",
}

-- Detailed diagnostics live in the optional TMOOC_KeepGearInventoryLogger mod.
local function Log(_) end

local function IsValid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function ObjectName(object)
    if not IsValid(object) then return "<invalid>" end
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and tostring(name) or tostring(object)
end

local function Unwrap(value)
    if value == nil then return nil end
    local result = value
    pcall(function() result = value:get() end)
    return result
end

local function AssetPath(object)
    local fullName = ObjectName(object)
    return fullName:match("^[^ ]+ (.+)$") or fullName
end

local function AddArrayItemsToSet(gameState, propertyName, targetSet)
    local items = nil
    pcall(function() items = gameState[propertyName] end)
    if items == nil then return nil end

    local count = nil
    pcall(function() count = items:GetArrayNum() end)
    if type(count) ~= "number" then return nil end

    for index = 1, count do
        local item = nil
        pcall(function() item = Unwrap(items[index]) end)
        if IsValid(item) then targetSet[AssetPath(item)] = true end
    end
    return count
end

local function RefreshNativeItemSets()
    local gameState = UEHelpers.GetGameStateBase()
    if not IsValid(gameState) then return end

    -- GameState item arrays are static for a map. Reading them once instead of
    -- on every inventory sample avoids repeated traversal of Unreal arrays.
    local gameStateName = ObjectName(gameState)
    if gameStateName == LastCatalogGameState then return end

    local now = os.clock()
    if now - LastCatalogRefreshAt < 10 then return end
    LastCatalogRefreshAt = now

    local shopCount = AddArrayItemsToSet(gameState, "ShopItemList", NativeStoreItemPaths)
    local treasureCount = AddArrayItemsToSet(gameState, "TreasureItems", NativeTreasureItemPaths)
    local falseTreasureCount = AddArrayItemsToSet(
        gameState, "FalseTreasureItems", NativeTreasureItemPaths)

    -- Do not cache an early, not-yet-populated GameState during map startup.
    if shopCount ~= nil and shopCount > 0 and
        treasureCount ~= nil and treasureCount > 0 and
        falseTreasureCount ~= nil and falseTreasureCount > 0 then
        LastCatalogGameState = gameStateName
        ItemKeepCache = {}
    end
end

local function ShouldKeepItem(item, fullName, path)
    if not IsValid(item) then return false end
    fullName = fullName or ObjectName(item)
    path = path or (fullName:match("^[^ ]+ (.+)$") or fullName)

    local cached = ItemKeepCache[path]
    if cached ~= nil then return cached end

    -- Treasure assets are sometimes typed as ZCItemWeapon, so this exclusion
    -- must run before any weapon, ammo, or native-store checks.
    if string.find(path, "/Blueprints/Pickups/Treasure/", 1, true) ~= nil or
        NativeTreasureItemPaths[path] == true then
        ItemKeepCache[path] = false
        return false
    end

    -- This special pickup crashes the listen server when reconstructed with
    -- ServerAddItemToInventory after extraction.
    if string.find(path, "SmellingSalts", 1, true) ~= nil then
        ItemKeepCache[path] = false
        return false
    end

    local isWeapon = string.find(path, "/Blueprints/Pawn/Weapons/", 1, true) ~= nil
    local isArmor = string.find(path, "/Blueprints/Pawn/Armor/", 1, true) ~= nil
    local isAmmo = string.find(fullName, "ZCItemAmmo ", 1, true) == 1 or
        string.find(path, "/Blueprints/Pickups/AmmoPacks/", 1, true) ~= nil
    local isConsumable = string.find(path, "/Blueprints/Consumables/", 1, true) ~= nil
    local isLightSource = string.find(path, "/Blueprints/Pickups/LightSources/", 1, true) ~= nil
    local isAllowedOther = false
    if string.find(path, "/Blueprints/Pickups/Other/", 1, true) ~= nil then
        for _, marker in ipairs(ALLOWED_OTHER_ITEM_MARKERS) do
            if string.find(path, marker, 1, true) ~= nil then
                isAllowedOther = true
                break
            end
        end
    end

    local keep = isWeapon or isArmor or isAmmo or isConsumable or isLightSource or
        isAllowedOther or NativeStoreItemPaths[path] == true
    ItemKeepCache[path] = keep
    return keep
end

local function IsSingleItemEquipment(fullName, path)
    fullName = fullName or ""
    path = path or ""
    return string.find(path, "/Blueprints/Pawn/Weapons/", 1, true) ~= nil or
        string.find(path, "/Blueprints/Pawn/Armor/", 1, true) ~= nil or
        string.find(fullName, "ZCItemWeapon ", 1, true) == 1
end

local function FindOrLoadAsset(path)
    local asset = StaticFindObject(path)
    if IsValid(asset) then return asset end
    pcall(function() asset = LoadAsset(path) end)
    if IsValid(asset) then return asset end
    return StaticFindObject(path)
end

local function CurrentPlayerController()
    local controllers = nil
    pcall(function() controllers = FindAllOf("PlayerController") or FindAllOf("Controller") end)
    if controllers ~= nil then
        for _, controller in ipairs(controllers) do
            if IsValid(controller) then
                local isLocal = false
                pcall(function() isLocal = controller:IsLocalPlayerController() end)
                if isLocal then return controller end
            end
        end
    end
    return UEHelpers.GetPlayerController()
end

local function CurrentWorld()
    local pc = CurrentPlayerController()
    if IsValid(pc) then
        local world = nil
        pcall(function() world = pc:GetWorld() end)
        if IsValid(world) then return world end
    end
    return UEHelpers.GetWorld()
end

local function IsLocalPlayerController(controller)
    if not IsValid(controller) then return false end
    local isLocal = false
    pcall(function() isLocal = controller:IsLocalPlayerController() end)
    return isLocal == true
end

local function ControllerWorldName(controller)
    local world = nil
    if IsValid(controller) then pcall(function() world = controller:GetWorld() end) end
    return ObjectName(world)
end

local function CurrentInventoryComponent()
    local pc = CurrentPlayerController()
    local inventory = nil
    if IsValid(pc) then pcall(function() inventory = pc.InventoryComponent end) end
    return inventory
end

local function ReadTravelBagInventory(inventoryOverride)
    RefreshNativeItemSets()
    local inventory = inventoryOverride
    if not IsValid(inventory) then inventory = CurrentInventoryComponent() end
    if not IsValid(inventory) then return nil end

    local array = nil
    pcall(function() array = inventory.TravelBagInventory end)
    if array == nil then return nil end

    local count = nil
    pcall(function() count = array:GetArrayNum() end)
    if type(count) ~= "number" then return nil end

    local records = {}
    for index = 1, count do
        local entry = nil
        pcall(function() entry = Unwrap(array[index]) end)
        if entry ~= nil then
            local item = nil
            local amount = 0
            pcall(function() item = entry.Item end)
            pcall(function() amount = tonumber(entry.Count) or 0 end)
            local fullName = ObjectName(item)
            local path = fullName:match("^[^ ]+ (.+)$") or fullName
            if ShouldKeepItem(item, fullName, path) then
                if IsSingleItemEquipment(fullName, path) then
                    local logKey = path .. ":" .. tostring(amount)
                    if amount ~= 1 and not NormalizedEquipmentLog[logKey] then
                        NormalizedEquipmentLog[logKey] = true
                        Log("SNAPSHOT normalized equipment count " .. path ..
                            " from x" .. tostring(amount) .. " to x1")
                    end
                    amount = 1
                end
                if amount > 0 then
                    table.insert(records, {
                        Path = path,
                        Count = amount,
                        Slot = index,
                    })
                end
            end
        end
    end
    return records
end

local function InventorySummary(records)
    if records == nil then return "unavailable" end
    local parts = {}
    for _, record in ipairs(records) do
        table.insert(parts, "slot" .. tostring(record.Slot) .. "=" ..
            record.Path .. " x" .. tostring(record.Count))
    end
    return #parts == 0 and "empty" or table.concat(parts, ", ")
end

local function InventoryCounts(records)
    local counts = {}
    if records == nil then return counts end
    for _, record in ipairs(records) do
        counts[record.Path] = (counts[record.Path] or 0) + record.Count
    end
    return counts
end

local function InventoryContains(current, expected)
    if current == nil or expected == nil then return false end
    local currentCounts = InventoryCounts(current)
    local expectedCounts = InventoryCounts(expected)
    for path, count in pairs(expectedCounts) do
        if (currentCounts[path] or 0) < count then return false end
    end
    return true
end

local function SortedInventoryRecords(records)
    local sorted = {}
    if records == nil then return sorted end
    for _, record in ipairs(records) do table.insert(sorted, record) end
    table.sort(sorted, function(left, right)
        return (tonumber(left.Slot) or 0) < (tonumber(right.Slot) or 0)
    end)
    return sorted
end

local function RemoveInventoryRecords(ps, records)
    local okAll = true
    for _, record in ipairs(records or {}) do
        local asset = FindOrLoadAsset(record.Path)
        if IsValid(asset) and record.Count > 0 then
            local ok, err = pcall(function()
                ps:ServerRemoveItemFromInventory(asset, record.Count)
            end)
            Log((ok and "RESTORE removed current " or "RESTORE remove failed ") ..
                "slot=" .. tostring(record.Slot) .. " " .. record.Path ..
                " x" .. tostring(record.Count) .. (ok and "" or (" error=" .. tostring(err))))
            okAll = okAll and ok
        end
    end
    return okAll
end

local function AddInventoryRecords(ps, records, prefix)
    local delay = 50
    for _, sourceRecord in ipairs(SortedInventoryRecords(records)) do
        local record = {
            Path = sourceRecord.Path,
            Count = sourceRecord.Count,
            Slot = sourceRecord.Slot,
        }
        ExecuteWithDelay(delay, function()
            local asset = FindOrLoadAsset(record.Path)
            if IsValid(asset) and record.Count > 0 then
                local ok, err = pcall(function()
                    ps:ServerAddItemToInventory(asset, record.Count)
                end)
                Log((ok and prefix or "RESTORE add failed ") ..
                    "slot=" .. tostring(record.Slot) .. " " .. record.Path ..
                    " x" .. tostring(record.Count) ..
                    (ok and "" or (" error=" .. tostring(err))))
            else
                Log("RESTORE asset unavailable " .. record.Path)
            end
        end)
        delay = delay + 250
    end
    return delay
end

local function AddMissingInventoryRecords(ps, current, expected)
    local availableCounts = InventoryCounts(current)
    local missingRecords = {}
    for _, record in ipairs(SortedInventoryRecords(expected)) do
        local available = availableCounts[record.Path] or 0
        local covered = math.min(available, record.Count)
        availableCounts[record.Path] = available - covered
        local missing = record.Count - covered
        if missing > 0 then
            table.insert(missingRecords, {
                Path = record.Path,
                Count = missing,
                Slot = record.Slot,
            })
        end
    end
    return AddInventoryRecords(ps, missingRecords, "RESTORE added missing ")
end

local function RestoreRaidInventory()
    if LastRaidInventory == nil then
        RestoreScheduled = false
        return
    end

    local pc = RestorePlayerController
    if not IsValid(pc) then pc = CurrentPlayerController() end
    local ps = nil
    if IsValid(pc) then pcall(function() ps = pc.PlayerState end) end
    local inventory = RestoreInventoryComponent
    if not IsValid(inventory) and IsValid(pc) then
        pcall(function() inventory = pc.InventoryComponent end)
    end
    local current = ReadTravelBagInventory(inventory)
    if not IsValid(ps) or current == nil then
        Log("RESTORE waiting for ship inventory")
        ExecuteWithDelay(1000, RestoreRaidInventory)
        return
    end

    Log("RESTORE begin saved=" .. InventorySummary(LastRaidInventory) ..
        " current=" .. InventorySummary(current))

    local removedCurrent = RemoveInventoryRecords(ps, current)
    if removedCurrent then
        ExecuteWithDelay(250, function()
            AddInventoryRecords(ps, LastRaidInventory, "RESTORE added ordered ")
        end)
    else
        Log("RESTORE ordered rebuild skipped; falling back to missing-only restore")
        AddMissingInventoryRecords(ps, current, LastRaidInventory)
    end

    local restoreSettleDelay = 1500 + (#LastRaidInventory * 250)
    ExecuteWithDelay(restoreSettleDelay, function()
        local result = ReadTravelBagInventory(inventory)
        Log("RESTORE result=" .. InventorySummary(result))
        if InventoryContains(result, LastRaidInventory) then
            Log("RESTORE complete")
            LastRaidInventory = nil
            WasInRaid = false
            RestoreScheduled = false
            RestoreAttempts = 0
            RaidPlayerController = nil
            RaidInventoryComponent = nil
            RestorePlayerController = nil
            RestoreInventoryComponent = nil
        elseif RestoreAttempts < 5 then
            RestoreAttempts = RestoreAttempts + 1
            Log("RESTORE retry=" .. tostring(RestoreAttempts))
            RestoreRaidInventory()
        else
            Log("RESTORE gave up after retries")
            LastRaidInventory = nil
            WasInRaid = false
            RestoreScheduled = false
        end
    end)
end

local function SaveRaidSnapshot(reason, inventoryOverride)
    local snapshot = ReadTravelBagInventory(inventoryOverride)
    if snapshot ~= nil and next(snapshot) ~= nil then
        LastRaidInventory = snapshot
        WasInRaid = true
        if reason ~= nil then
            Log("RAID snapshot saved (" .. tostring(reason) .. ")=" ..
                InventorySummary(snapshot))
        end
        return true
    end
    if reason ~= nil then
        Log("RAID snapshot skipped (" .. tostring(reason) .. ")=" ..
            InventorySummary(snapshot))
    end
    return false
end

RegisterLoadMapPreHook(function()
    if WasInRaid and IsValid(RaidInventoryComponent) then
        SaveRaidSnapshot("before map travel", RaidInventoryComponent)
    end
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(context)
    local controller = Unwrap(context)
    if not IsLocalPlayerController(controller) then return end

    local worldName = ControllerWorldName(controller)
    if string.find(worldName, "MasterMap", 1, true) then
        RaidPlayerController = controller
        RaidInventoryComponent = nil
        pcall(function() RaidInventoryComponent = controller.InventoryComponent end)
        RestorePlayerController = nil
        RestoreInventoryComponent = nil
        LastRaidInventory = nil
        WasInRaid = true
        RestoreScheduled = false
        RestoreAttempts = 0

        -- One baseline snapshot also covers unusual travel paths where the
        -- pre-load hook cannot access the old raid component anymore.
        ExecuteWithDelay(1500, function()
            if WasInRaid and IsValid(RaidInventoryComponent) then
                SaveRaidSnapshot("raid started", RaidInventoryComponent)
            end
        end)
    elseif string.find(worldName, "Galleon", 1, true) and
        WasInRaid and LastRaidInventory ~= nil and not RestoreScheduled then
        RestorePlayerController = controller
        RestoreInventoryComponent = nil
        pcall(function() RestoreInventoryComponent = controller.InventoryComponent end)
        RestoreScheduled = true
        RestoreAttempts = 0
        ExecuteWithDelay(1500, RestoreRaidInventory)
    end
end)
