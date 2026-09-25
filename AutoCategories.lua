local _, VA = ...

-- Sorts items into categories from item class and tooltip text.
-- Runs once per item; manual edits afterwards are never overwritten.

local BATCH, INTERVAL, MAX_ATTEMPTS = 25, 0.2, 10

local CLASS = {
    Consumable = 0, Container = 1, Weapon = 2, Armor = 4, Reagent = 5, Projectile = 6,
    TradeGoods = 7, ItemEnhancement = 8, Recipe = 9, Quiver = 11, Quest = 12, Misc = 15, BattlePet = 17,
}
local MISC_PET, MISC_MOUNT = 2, 5
local PROJECTILE_ARROW, PROJECTILE_BULLET = 2, 3
local WEAPON_FISHING_POLE = 20
local ARMOR_MISC = 0

-- Name keyword -> professions using it as material
local MATERIALS = {
    { "thread", "Tailoring", "Leatherworking" },
    { "dye", "Tailoring", "Leatherworking" },
    { "salt", "Leatherworking" },
    { "flux", "Blacksmithing", "Engineering" },
    { "coal", "Blacksmithing" },
    { "wiring", "Engineering" },
    { "vial", "Alchemy", "Enchanting" },
    { "simple wood", "Enchanting" },
    { "copper rod", "Enchanting" },
    { "spice", "Cooking" },
    { "flour", "Cooking" },
    { "seasoning", "Cooking" },
}

local TOOLS = { "mining pick", "skinning knife", "blacksmith hammer", "arclight spanner", "gyromatic" }

local CLASS_REAGENTS = {
    "flash powder", "blinding powder", "symbol of", "holy candle", "sacred candle", "ankh",
    "rune of teleportation", "rune of portals", "arcane powder", "light feather", "wild berries",
    "wild thornroot", "maple seed", "stranglethorn seed", "ashwood seed", "hornbeam seed", "ironwood seed",
    "infernal stone", "demonic figurine", "fish oil", "shiny fish scales",
}

local POISON_REAGENTS = { "dust of decay", "essence of pain", "deathweed", "maiden's anguish", "dust of deterioration", "essence of agony" }

local WEAPON_ENHANCEMENTS = { "sharpening stone", "weightstone", "wizard oil", "mana oil" }

local EXPLOSIVES = { "bomb", "dynamite", "grenade", "explosive" }

local PVP_RANKS = {}
for _, rank in ipairs({
    "Private", "Corporal", "Sergeant", "Master Sergeant", "Sergeant Major", "Knight", "Knight-Lieutenant",
    "Knight-Captain", "Knight-Champion", "Lieutenant Commander", "Commander", "Marshal", "Field Marshal", "Grand Marshal",
    "Scout", "Grunt", "Senior Sergeant", "First Sergeant", "Stone Guard", "Blood Guard", "Legionnaire",
    "Centurion", "Champion", "Lieutenant General", "General", "Warlord", "High Warlord",
}) do PVP_RANKS[rank] = true end

local PVP_FACTIONS = {
    ["Frostwolf Clan"] = true, ["Stormpike Guard"] = true, ["Silverwing Sentinels"] = true,
    ["Warsong Outriders"] = true, ["The League of Arathor"] = true, ["The Defilers"] = true,
}

local STANDINGS = { Neutral = true, Friendly = true, Honored = true, Revered = true, Exalted = true }

-- Helpers -------------------------------------------------------------------

local function HasAny(text, words)
    for _, word in ipairs(words) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

local function TooltipLines(itemID)
    local data = C_TooltipInfo and C_TooltipInfo.GetItemByID(itemID)
    if not (data and data.lines) then return end
    local lines = {}
    for _, line in ipairs(data.lines) do
        if line.leftText then lines[#lines + 1] = line.leftText end
        if line.rightText then lines[#lines + 1] = line.rightText end
    end
    return lines
end

local function LevelBracket(level)
    local low = math.floor((math.max(level, 1) - 1) / 10) * 10 + 1
    return ("Leveling/Gear %d-%d"):format(low, low + 9)
end

-- Classifier ------------------------------------------------------------------

-- Returns a list of category paths, or nil if item data is not loaded yet
local function Classify(itemID)
    if not C_Item.IsItemDataCachedByID(itemID) then
        C_Item.RequestLoadItemDataByID(itemID)
        return
    end
    local name, _, _, _, minLevel, _, _, _, _, _, _, _, _, _, _, _, isReagent = C_Item.GetItemInfo(itemID)
    local lines = TooltipLines(itemID)
    if not (name and lines) then return end

    local _, _, subType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    local lname = strlower(name)
    local text = strlower(table.concat(lines, "\n"))
    local equippable = equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
    local paths = {}
    local function Add(path) paths[#paths + 1] = path end

    -- Requirement lines: PvP rank, reputation, riding
    local pvp, riding = false, false
    for _, line in ipairs(lines) do
        local req = line:match("^Requires (.+)$")
        if req then
            local faction, standing = req:match("^(.+) %- (%a+)$")
            if PVP_RANKS[req] then
                pvp = true
                Add("PvP/Rank Rewards")
            elseif faction and STANDINGS[standing] then
                if PVP_FACTIONS[faction] then
                    pvp = true
                    Add("PvP/Battleground Rewards")
                else
                    Add("Reputation/" .. faction)
                end
            elseif req:find("Riding", 1, true) then
                riding = true
            end
        end
    end
    -- Recipe tooltips embed the crafted item, so skip the item rules
    if classID == CLASS.Recipe then
        Add(subclassID == 0 and "Class Supplies/Books" or ("Professions/" .. subType .. "/Recipes"))
        return paths
    end

    local item = VA.db.items[itemID]
    for _, offer in pairs(item and item.vendors or {}) do
        if offer.pvp and not pvp then
            pvp = true
            Add("PvP/Battleground Rewards")
        end
    end

    -- Mounts and pets
    if riding or text:find("rideable", 1, true) or (classID == CLASS.Misc and subclassID == MISC_MOUNT) then
        Add("Mounts")
    elseif classID == CLASS.BattlePet or (classID == CLASS.Misc and subclassID == MISC_PET)
        or text:find("summon and dismiss", 1, true) then
        Add("Pets")
    end

    -- Consumables
    if classID == CLASS.Projectile then
        Add(subclassID == PROJECTILE_ARROW and "Consumables/Ammo/Arrows"
            or subclassID == PROJECTILE_BULLET and "Consumables/Ammo/Bullets"
            or "Consumables/Ammo")
    end
    local isFoodDrink = text:find("while eating", 1, true) or text:find("while drinking", 1, true)
        or (classID == CLASS.Consumable and not HasAny(lname, { "potion", "elixir", "flask" }))
    local health = isFoodDrink and text:find("restores[^\n]-health")
    local mana = isFoodDrink and text:find("restores[^\n]-mana")
    if health then Add("Consumables/Food & Drink/Food") end
    if mana then Add("Consumables/Food & Drink/Mana") end
    if text:find("well fed", 1, true) then Add("Consumables/Food & Drink/Buff Food") end

    if classID == CLASS.Consumable and not (health or mana) then
        local before = #paths
        if lname:find("potion", 1, true) then Add("Consumables/Potions") end
        if lname:find("elixir", 1, true) then Add("Consumables/Elixirs") end
        if lname:find("flask", 1, true) then Add("Consumables/Flasks") end
        if lname:find("scroll of", 1, true) then Add("Consumables/Scrolls") end
        if lname:find("bandage", 1, true) then Add("Consumables/Bandages") end
        if lname:find("poison", 1, true) then Add("Class Supplies/Poisons") end
        if HasAny(lname, EXPLOSIVES) then Add("Consumables/Explosives") end
        if text:find("fishing pole", 1, true) then Add("Professions/Fishing/Lures") end
        if #paths == before and not HasAny(lname, WEAPON_ENHANCEMENTS) then Add("Consumables/Other") end
    end
    if classID == CLASS.ItemEnhancement or HasAny(lname, WEAPON_ENHANCEMENTS) then
        Add("Consumables/Weapon Enhancements")
    end

    -- Class supplies
    if classID == CLASS.Reagent or HasAny(lname, CLASS_REAGENTS) then Add("Class Supplies/Reagents") end
    if HasAny(lname, POISON_REAGENTS) then Add("Class Supplies/Poisons") end

    -- Professions
    if HasAny(lname, TOOLS) then Add("Professions/Tools") end
    if not equippable and (classID == CLASS.TradeGoods or classID == CLASS.Misc or isReagent) then
        local matched = false
        for _, rule in ipairs(MATERIALS) do
            if lname:find(rule[1], 1, true) then
                matched = true
                for i = 2, #rule do Add("Professions/" .. rule[i] .. "/Materials") end
            end
        end
        if not matched and classID == CLASS.TradeGoods then Add("Professions/Other Materials") end
    end

    -- Gear
    if classID == CLASS.Container then Add("Gear/Bags") end
    if classID == CLASS.Quiver then Add("Gear/Quivers & Pouches") end
    if equippable and classID == CLASS.Weapon and subclassID == WEAPON_FISHING_POLE then
        Add("Professions/Fishing/Poles")
    elseif equippable and (classID == CLASS.Weapon or classID == CLASS.Armor) then
        if classID == CLASS.Weapon then
            Add("Gear/Weapons/" .. subType)
        elseif subclassID == ARMOR_MISC then
            Add("Gear/Accessories/" .. (_G[equipLoc] or subType))
        else
            Add("Gear/Armor/" .. subType)
        end
        if not pvp and minLevel and minLevel > 0 then Add(LevelBracket(minLevel)) end
    end

    if classID == CLASS.Quest then Add("Quest Items") end

    return paths
end

-- Queue -------------------------------------------------------------------

local queue, head, tail = {}, 1, 0
local queued, attempts = {}, {}
local ticker

local function Push(itemID)
    tail = tail + 1
    queue[tail] = itemID
    queued[itemID] = true
end

local function Process()
    local changed = false
    for _ = 1, BATCH do
        if head > tail then break end
        local itemID = queue[head]
        queue[head], head = nil, head + 1
        queued[itemID] = nil

        if VA.db.items[itemID] and not VA.db.autoDone[itemID] then
            local paths = Classify(itemID)
            if paths then
                for _, path in ipairs(paths) do
                    VA:AssignItem(itemID, VA:AddCategory(path))
                end
                VA.db.autoDone[itemID] = true
                changed = changed or #paths > 0
            else
                attempts[itemID] = (attempts[itemID] or 0) + 1
                if attempts[itemID] < MAX_ATTEMPTS then Push(itemID) end
            end
        end
    end

    if head > tail then
        ticker:Cancel()
        ticker, head, tail = nil, 1, 0
    end
    if changed then VA:OnDataChanged() end
end

function VA:QueueAutoCategorize(itemID)
    if self.db.autoDone[itemID] or queued[itemID] then return end
    attempts[itemID] = nil
    Push(itemID)
    if not ticker then ticker = C_Timer.NewTicker(INTERVAL, Process) end
end

-- Re-runs the classifier for items that are in no category
function VA:AutoCategorizeUncategorized()
    local count = 0
    for itemID in pairs(self.db.items) do
        if not self.db.itemCats[itemID] then
            self.db.autoDone[itemID] = nil
            self:QueueAutoCategorize(itemID)
            count = count + 1
        end
    end
    return count
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    for itemID in pairs(VA.db.items) do VA:QueueAutoCategorize(itemID) end
end)
