local _, VA = ...

VA.ALL, VA.UNCAT = "__all", "__uncat"

local DEFAULTS = {
    "Consumables/Food & Drink",
    "Consumables/Ammo",
    "Professions/Tailoring/Recipes",
    "Professions/Tailoring/Materials",
    "Professions/Leatherworking/Recipes",
    "Professions/Leatherworking/Materials",
}

local function IsUnder(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

function VA:ParentPath(path)
    return path:match("^(.*)/[^/]+$")
end

function VA:IsCategory(path)
    return path ~= self.ALL and path ~= self.UNCAT
end

-- " Professions//Tailoring " -> "Professions/Tailoring"
function VA:NormalizePath(text)
    local parts = {}
    for part in text:gmatch("[^/]+") do
        part = strtrim(part)
        if part ~= "" then parts[#parts + 1] = part end
    end
    return #parts > 0 and table.concat(parts, "/") or nil
end

-- Moves every path under old to new, or deletes them when new is nil
local function Remap(set, old, new)
    local moved = {}
    for path in pairs(set) do
        if IsUnder(path, old) then moved[#moved + 1] = path end
    end
    for _, path in ipairs(moved) do
        set[path] = nil
        if new then set[new .. path:sub(#old + 1)] = true end
    end
end

function VA:InitCategories()
    local db = self.db
    db.itemCats = db.itemCats or {}
    db.collapsed = db.collapsed or {}
    db.autoDone = db.autoDone or {}

    -- 1.3: categories no longer sit under a "Base" root
    if db.categories and not db.baseRemoved then
        local function Strip(set)
            local out = {}
            for path in pairs(set) do
                if path ~= "Base" then out[(path:gsub("^Base/", ""))] = true end
            end
            return out
        end
        db.categories = Strip(db.categories)
        db.collapsed = Strip(db.collapsed)
        for itemID, set in pairs(db.itemCats) do
            local stripped = Strip(set)
            db.itemCats[itemID] = next(stripped) and stripped or nil
        end
    end
    db.baseRemoved = true

    if not db.categories then
        db.categories = {}
        for _, path in ipairs(DEFAULTS) do self:AddCategory(path) end
    end
end

function VA:AddCategory(text)
    local path = self:NormalizePath(text)
    if not path then return end
    local db = self.db
    local prefix, parent
    for part in path:gmatch("[^/]+") do
        parent, prefix = prefix, prefix and (prefix .. "/" .. part) or part
        if not db.categories[prefix] then
            -- New categories start folded, and so does a parent getting its first child
            if parent and not self:HasChildren(parent) then db.collapsed[parent] = true end
            db.categories[prefix] = true
            if prefix ~= path then db.collapsed[prefix] = true end
        end
    end
    return path
end

function VA:HasChildren(path)
    local prefix = path .. "/"
    for other in pairs(self.db.categories) do
        if other:sub(1, #prefix) == prefix then return true end
    end
    return false
end

function VA:RenameCategory(old, text)
    local new = self:NormalizePath(text)
    if not new or new == old or IsUnder(new, old) then return end
    local db = self.db
    Remap(db.categories, old, new)
    Remap(db.collapsed, old, new)
    for _, set in pairs(db.itemCats) do Remap(set, old, new) end
    self:AddCategory(new)
    return new
end

function VA:DeleteCategory(path)
    local db = self.db
    Remap(db.categories, path)
    Remap(db.collapsed, path)
    for itemID, set in pairs(db.itemCats) do
        Remap(set, path)
        if not next(set) then db.itemCats[itemID] = nil end
    end
end

function VA:AssignItem(itemID, path)
    local set = self.db.itemCats[itemID] or {}
    self.db.itemCats[itemID] = set
    set[path] = true
end

-- Removes the item from root and all of its subcategories
function VA:UnassignItem(itemID, root)
    local set = self.db.itemCats[itemID]
    if not set then return end
    Remap(set, root)
    if not next(set) then self.db.itemCats[itemID] = nil end
end

function VA:ItemInCategory(itemID, root)
    local set = self.db.itemCats[itemID]
    if root == self.ALL then return true end
    if root == self.UNCAT then return not set end
    if not set then return false end
    for path in pairs(set) do
        if IsUnder(path, root) then return true end
    end
    return false
end
