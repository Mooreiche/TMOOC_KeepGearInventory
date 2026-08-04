local UEHelpers = require("UEHelpers")

local LOG_PATH =
    "C:/Program Files (x86)/Steam/steamapps/common/The Mound/TheMound/Binaries/Win64/ue4ss/Mods/" ..
    "TMOOC_KeepGearInventory-main/TMOOC_KeepGearInventory-main.log"

local PLAYER_STATE_CLASS = "/Game/TheMound/Blueprints/Game/BP_TMPlayerState.BP_TMPlayerState_C"
local LastRaidInventory = nil
local WasInRaid = false
local DiedThisRaid = false
local RestoreScheduled = false
local RestoreAttempts = 0
local DeathHookRegistered = false
local NativeStoreItemPaths = {}
local NativeTreasureItemPaths = {}
local ItemKeepCache = {}
local LastCatalogGameState = nil

local ALLOWED_OTHER_ITEM_MARKERS = {
    "DiviningRod", "Yig", "CurseJar", "Ichor", "Nyarlathotep", "Mask",
    "Crucifix", "Medallion", "SoundBowl", "SlaveFinder", "SmellingSalts",
    "Ammonia", "Map_", "Lantern",
}

local function Log(message)
    local line = os.date("%Y-%m-%d %H:%M:%S") ..
        " [TMOOC_KeepGearInventory-main] " .. tostring(message)
    print(line .. "\n")
    local file = io.open(LOG_PATH, "a")
    if file then
        file:write(line .. "\n")
        file:close()
    end
end

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

    local gameStateName = ObjectName(gameState)
    if gameStateName == LastCatalogGameState then return end

    local shopCount = AddArrayItemsToSet(gameState, "ShopItemList", NativeStoreItemPaths)
    local treasureCount = AddArrayItemsToSet(gameState, "TreasureItems", NativeTreasureItemPaths)
    local falseTreasureCount = AddArrayItemsToSet(
        gameState, "FalseTreasureItems", NativeTreasureItemPaths)

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

    if string.find(path, "/Blueprints/Pickups/Treasure/", 1, true) ~= nil or
        NativeTreasureItemPaths[path] == true then
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

local function FindOrLoadAsset(path)
    local asset = StaticFindObject(path)
    if IsValid(asset) then return asset end
    pcall(function() asset = LoadAsset(path) end)
    if IsValid(asset) then return asset end
    return StaticFindObject(path)
end

local function CurrentInventoryComponent()
    local pc = UEHelpers.GetPlayerController()
    local inventory = nil
    if IsValid(pc) then pcall(function() inventory = pc.InventoryComponent end) end
    return inventory
end

local function IsLocalPlayerState(context)
    context = Unwrap(context)
    if not IsValid(context) then return false end

    local pc = UEHelpers.GetPlayerController()
    local playerState = nil
    if IsValid(pc) then pcall(function() playerState = pc.PlayerState end) end
    if not IsValid(playerState) then return false end
    return context == playerState or ObjectName(context) == ObjectName(playerState)
end

local function DiscardRaidInventory(reason)
    if LastRaidInventory ~= nil or WasInRaid or RestoreScheduled then
        Log("DISCARD saved inventory: " .. tostring(reason))
    end
    LastRaidInventory = nil
    WasInRaid = false
    DiedThisRaid = true
    RestoreScheduled = false
    RestoreAttempts = 0
end

local function RegisterDeathHook()
    if DeathHookRegistered then return end

    local ok = pcall(function()
        RegisterHook("/Script/TheMound.TMPlayerState:ServerNotifySpectatingSelf",
            function(context, spectatingParam)
                local spectating = Unwrap(spectatingParam)
                if spectating == true and IsLocalPlayerState(context) then
                    DiscardRaidInventory("local player died")
                end
            end)
    end)

    if ok then
        DeathHookRegistered = true
        Log("Death detection ready.")
    else
        ExecuteWithDelay(5000, RegisterDeathHook)
    end
end

local function ReadTravelBagInventory()
    RefreshNativeItemSets()
    local inventory = CurrentInventoryComponent()
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
            if ShouldKeepItem(item, fullName, path) and amount > 0 then
                table.insert(records, {
                    Path = path,
                    Count = amount,
                    Slot = index,
                })
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

local function RestoreRaidInventory()
    if LastRaidInventory == nil then
        RestoreScheduled = false
        return
    end

    local pc = UEHelpers.GetPlayerController()
    local ps = nil
    if IsValid(pc) then pcall(function() ps = pc.PlayerState end) end
    local current = ReadTravelBagInventory()
    if not IsValid(ps) or current == nil then
        Log("RESTORE waiting for ship inventory")
        ExecuteWithDelay(1000, RestoreRaidInventory)
        return
    end

    Log("RESTORE begin saved=" .. InventorySummary(LastRaidInventory) ..
        " current=" .. InventorySummary(current))
    local availableCounts = InventoryCounts(current)
    for _, record in ipairs(LastRaidInventory) do
        local available = availableCounts[record.Path] or 0
        local covered = math.min(available, record.Count)
        availableCounts[record.Path] = available - covered
        local missing = record.Count - covered
        if missing > 0 then
            local asset = FindOrLoadAsset(record.Path)
            if IsValid(asset) then
                local ok, err = pcall(function()
                    ps:ServerAddItemToInventory(asset, missing)
                end)
                Log((ok and "RESTORE added " or "RESTORE failed ") ..
                    "slot=" .. tostring(record.Slot) .. " " .. record.Path ..
                    " x" .. tostring(missing) .. (ok and "" or (" error=" .. tostring(err))))
            else
                Log("RESTORE asset unavailable " .. record.Path)
            end
        end
    end

    ExecuteWithDelay(1000, function()
        local result = ReadTravelBagInventory()
        Log("RESTORE result=" .. InventorySummary(result))
        if InventoryContains(result, LastRaidInventory) then
            Log("RESTORE complete")
            LastRaidInventory = nil
            WasInRaid = false
            RestoreScheduled = false
            RestoreAttempts = 0
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

local function MonitorExtractionTransition()
    ExecuteInGameThread(function()
        local worldName = ObjectName(UEHelpers.GetWorld())
        if string.find(worldName, "MasterMap", 1, true) then
            if not DiedThisRaid then
                local snapshot = ReadTravelBagInventory()
                if snapshot ~= nil and next(snapshot) ~= nil then
                    LastRaidInventory = snapshot
                    WasInRaid = true
                end
            end
        elseif string.find(worldName, "Galleon", 1, true) then
            if DiedThisRaid then
                DiedThisRaid = false
            elseif WasInRaid and LastRaidInventory ~= nil and not RestoreScheduled then
                RestoreScheduled = true
                RestoreAttempts = 0
                Log("EXTRACT transition detected; saved=" .. InventorySummary(LastRaidInventory))
                ExecuteWithDelay(1500, RestoreRaidInventory)
            end
        end
    end)
    ExecuteWithDelay(1000, MonitorExtractionTransition)
end

local session = io.open(LOG_PATH, "w")
if session then
    session:write("TMOOC_KeepGearInventory-main session started " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    session:close()
end

MonitorExtractionTransition()
RegisterDeathHook()
Log("Loaded (production mode).")
