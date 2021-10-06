local tdraw = require("tiledraw")

debugMode = true

local HEALTH_BAR_Y_TABLE = 0xCFE2
local HEALTH_BAR_TILES = 0xCFE9

local gameState = 0

-- Another approach to this problem might be to force $06 (OAM counter) to always be 0 so the game always draws,
-- then monitor whatever it tries to write. But that would alter game function.

local function drawEnergyBar(energy, x, palette)
    for i = 6, 0, -1 do
        local y = memory.readbyte(HEALTH_BAR_Y_TABLE + i)
        local tile
        if energy < 4 then
            tile = memory.readbyte(HEALTH_BAR_TILES + energy)
            energy = 0
        else
            tile = 0x87
            energy = energy - 4
        end
        
        tdraw.bufferDraw(y, palette, tile, x)
        
    end
end

local function drawEnergyBars()

    -- if true then return end
    
    local health = memory.readbyte(0x06C0)
    drawEnergyBar(health, 0x18, 1)
    
    local equippedWeapon = memory.readbyte(0xA9)
    if equippedWeapon ~= 0 then
        local weaponEnergy = memory.readbyte(0x9B + equippedWeapon)
        drawEnergyBar(weaponEnergy, 0x10, 0)
    end
    
    local bossFlag = memory.readbyte(0xB1)
    if bossFlag ~= 0 then
        local bossIndex = memory.readbyte(0xB3)
        local bossHealth = memory.readbyte(0x06C1)
        local palette = (bossIndex == 8 or bossIndex == 0xD) and 1 or 3
        drawEnergyBar(bossHealth, 0x28, palette)
    end
    
end

local normalGfx = false
local frozenGfx = false
local pauseMenuGfx = false
local pauseMenuInit = false

local function drawSpritesNormal()
    tdraw.clearBuffer()
    drawEnergyBars()
end

local function drawSpritesFrozen()
    tdraw.clearBuffer()
    drawEnergyBars()
end

local function drawSpritesPauseMenu()
    tdraw.clearBuffer()
end

local prevGameState = memory.readbyte(0x01FE)

local function drawSpritesMenuPopup()
    -- This routine is reused by menu popup and scrolling. Since I don't feel like reverse engineering that right now,
    -- I'm using hacky gamestate jank until I do.
    if gameState ~= 156 and prevGameState ~= 156 then
        tdraw.clearBuffer()
    end
end

local function drawSprites()
    
    prevGameState = gameState
    gameState = memory.readbyte(0x01FE)
    
    tdraw.renderBuffer()

    -- Sometimes appears one frame before it's supposed to in boss fights.
    -- Has to do with that one lag frame you sometimes get. Is there another callback to look for?
    
    if gameState == 78 or gameState == 120 or gameState == 129 or gameState == 195 or gameState == 197 then
        if debugMode then gui.text(100, 10, "Get equipped/Castle/Death") end
        tdraw.clearBuffer()
    elseif normalGfx then
        if debugMode then gui.text(100, 10, "Normal gfx") end
        drawSpritesNormal()
        normalGfx = false
    elseif frozenGfx then
        if debugMode then gui.text(100, 10, "Frozen gfx") end
        drawSpritesFrozen()
        frozenGfx = false
    elseif pauseMenuGfx then
        if debugMode then gui.text(100, 10, "Pause menu gfx") end
        drawSpritesPauseMenu()
        pauseMenuGfx = false
    elseif pauseMenuInit then
        if debugMode then gui.text(100, 10, "Menu routine") end
        drawSpritesMenuPopup()
        pauseMenuInit = false
    else
        if debugMode then gui.text(100, 10, "None") end
    end
    
end

local function postFrame()
    
end

local function normalGfxRoutineCallback(address, bank)
    normalGfx = true
end

local function timeFrozenGfxRoutineCallback()
    frozenGfx = true
end

local function pauseMenuGfxRoutineCallback()
    pauseMenuGfx = true
end

local function menuInitRoutineCallback()
    pauseMenuInit = true
end

local function ppuRegCallback(address, size, value)
    -- print(string.format("Wrote to $%04X: #$%02X", address, value))
    if address == 0x2000 then
        tdraw.updatePpuCtrl(value)
    elseif address == 0x2001 then
        tdraw.updatePpuMask(value)
    end
end

-- This is EXTREMELY Mega Man 2 specific, sadly. I happen to know that it uses the MMC1 mode
-- that always maps F to $C000 - $FFFF and swaps 0 - E into $8000 - $BFFF. I also happen to know
-- that is uses $29 as an in-memory mirror for the current low-address bank number.
-- Could be onto something good here if we could read the mapper state.
-- FCEUX has an internal function that provides this information; should expose it to Lua.
local function getBank()
    local pc = memory.getregister("PC")
    
    if pc >= 0xC000 then
        return 0xF
    else
        return memory.readbyte(0x29)
    end
end

-- I plan to add this as an actual callback in FCEUX
local function bankDecorator(address, bank, callback)
    return function()
        if getBank() == bank then
            callback(address, bank)
        end
    end
end

local function registerAddressBanked(address, bank, callback)
    memory.registerexec(address, bankDecorator(address, bank, callback))
end

-- gui.register(drawSprites)
emu.registerafter(drawSprites)

registerAddressBanked(0xCC8B, 0xF, normalGfxRoutineCallback)
registerAddressBanked(0xCD02, 0xF, timeFrozenGfxRoutineCallback)
registerAddressBanked(0x9396, 0xD, pauseMenuGfxRoutineCallback)
registerAddressBanked(0x90EF, 0xD, menuInitRoutineCallback) -- This is just the address where it clears OAM. More analysis needed.

memory.registerwrite(0x2000, 7, ppuRegCallback)
