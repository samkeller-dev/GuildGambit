-- UI/Art.lua: textures. Our own art ships in Media/ (PNG, with TGA copies as a fallback);
-- portraits and the elite dragon frames are the game's own, referenced from the client.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Art = {}
ns.Art = Art

Art.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"

--- Path to one of our textures, e.g. Art.Tex("cards/As"). PNG by default; "/gg art tga"
--- switches to the TGA copies if PNG ever fails to load.
function Art.Tex(name)
    local ext = (ns.db and ns.db.textureExt) or "png"
    return Art.MEDIA .. name:gsub("/", "\\") .. "." .. ext
end

---------------------------------------------------------------------------
-- Game textures (all paths/atlases used by Blizzard's own UI)
---------------------------------------------------------------------------
Art.GAME = {
    dialogBorder = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    dialogBg = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    dialogHeader = "Interface\\DialogFrame\\UI-DialogBox-Header",
    parchment = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
    marble = "Interface\\FrameGeneral\\UI-Background-Marble",
    portraitMask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    dice = "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
}

-- Elite dragon frames from Blizzard's target frame. Geometry: native atlas size, where the
-- portrait's centre sits (fraction of width/height) and the portrait diameter as a fraction of
-- the atlas width. Calibrate in-game with /gg art <kind> <cx> <cy> <scale>.
Art.ELITE = {
    winged = { atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged", w = 99, h = 81, cx = 0.40, cy = 0.56, d = 0.59, fallback = "frames/dragon_gold" },
    gold = { atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold", w = 80, h = 79, cx = 0.47, cy = 0.55, d = 0.72, fallback = "frames/dragon_gold" },
    silver = { atlas = "ui-hud-unitframe-target-portraiton-boss-rare-silver", w = 80, h = 79, cx = 0.47, cy = 0.55, d = 0.72, fallback = "frames/dragon_silver" },
    -- Blizzard has no bronze dragon: the gold elite dragon, desaturated and tinted bronze
    bronze = { atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold", w = 80, h = 79, cx = 0.47, cy = 0.55, d = 0.72,
        tint = { 0.95, 0.6, 0.35 }, desaturate = true, fallback = "frames/dragon_bronze" },
}

-- Our own ring frames: window centre and radius in the 256px texture.
Art.RING = { cx = 124 / 256, cy = 146 / 256, d = 2 * 54 / 256 }

local atlasCache = {}
function Art.HasAtlas(name)
    if atlasCache[name] == nil then
        local get = C_Texture and C_Texture.GetAtlasInfo
        local ok, info = false, nil
        if get then ok, info = pcall(get, name) end
        atlasCache[name] = (ok and info ~= nil) and true or false
    end
    return atlasCache[name]
end

local function EliteGeometry(kind)
    local g = Art.ELITE[kind]
    local o = ns.db and ns.db.art and ns.db.art[kind]
    if o then
        return { atlas = g.atlas, w = g.w, h = g.h, cx = o.cx or g.cx, cy = o.cy or g.cy, d = o.d or g.d,
            tint = g.tint, desaturate = g.desaturate, fallback = g.fallback }
    end
    return g
end

---------------------------------------------------------------------------
-- Portrait icons
---------------------------------------------------------------------------
-- Card suits -> races (the in-game icons are Interface\Icons\INV_Misc_Head_<Race>_01/02).
Art.SUIT_RACE = { s = "Orc", h = "Human", d = "Elf", c = "Dwarf" }
Art.SUIT_DRAGON = { s = "Black", h = "Red", d = "Blue", c = "Green" }

-- Player races (UnitRace's second return) -> icon race names.
local RACE_ICON = {
    Human = "Human", Orc = "Orc", Dwarf = "Dwarf", NightElf = "Elf", BloodElf = "Elf",
    Scourge = "Undead", Undead = "Undead", Tauren = "Tauren", Gnome = "Gnome", Troll = "Troll",
}

function Art.HeadIcon(race, female)
    return ("Interface\\Icons\\INV_Misc_Head_%s_%s"):format(race, female and "02" or "01")
end

function Art.DragonIcon(color)
    return "Interface\\Icons\\INV_Misc_Head_Dragon_" .. color
end

--- Icon for a player from the race file name and UnitSex value (3 = female).
function Art.PlayerIcon(raceFile, sex)
    local race = raceFile and RACE_ICON[raceFile]
    if not race then return Art.GAME.unknown end
    return Art.HeadIcon(race, tonumber(sex) == 3)
end

---------------------------------------------------------------------------
-- Portrait widget: round game icon + a frame (our ring, or Blizzard's elite dragon)
---------------------------------------------------------------------------
--- frameKind: nil | "ring_gold" | "ring_silver" | "winged" | "gold" | "silver"
function Art.CreatePortrait(parent, diameter)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(diameter, diameter)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetAllPoints()
    p.mask = p:CreateMaskTexture()
    p.mask:SetAllPoints(p.icon)
    p.mask:SetTexture(Art.GAME.portraitMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    p.icon:AddMaskTexture(p.mask)
    p.frame = p:CreateTexture(nil, "OVERLAY")
    p.diameter = diameter
    return p
end

function Art.SetPortrait(p, iconPath, frameKind)
    p.icon:SetTexture(iconPath or Art.GAME.unknown)
    local f, d = p.frame, p.diameter
    f:ClearAllPoints()
    if not frameKind then f:Hide() return end
    f:Show()
    local useAtlas, g
    if Art.ELITE[frameKind] then
        g = EliteGeometry(frameKind)
        useAtlas = Art.HasAtlas(g.atlas) and not (ns.db and ns.db.ownDragons)
    end
    f:SetDesaturated(false)
    f:SetVertexColor(1, 1, 1)
    if useAtlas then
        local scale = d / (g.w * g.d)
        local w, h = g.w * scale, g.h * scale
        f:SetAtlas(g.atlas, false)
        f:SetSize(w, h)
        f:SetPoint("TOPLEFT", p, "CENTER", -g.cx * w, g.cy * h)
        if g.desaturate then f:SetDesaturated(true) end
        if g.tint then f:SetVertexColor(g.tint[1], g.tint[2], g.tint[3]) end
    else
        -- our textures: the dragon fallback or a plain ring, both 256x256 with the same window
        local tex = g and g.fallback or ("frames/" .. frameKind)
        local size = d / Art.RING.d
        f:SetTexture(Art.Tex(tex))
        f:SetSize(size, size)
        f:SetPoint("TOPLEFT", p, "CENTER", -Art.RING.cx * size, Art.RING.cy * size)
    end
end
