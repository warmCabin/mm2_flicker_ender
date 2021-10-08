local tdraw = require("tiledraw")

debugMode = arg:find("--debug")

local HEALTH_BAR_Y_TABLE = 0xCFE2
local HEALTH_BAR_TILES = 0xCFE9

local SPRITE_FLAGS = 0x0420
local SPRITE_IDS = 0x0400

local SPRITE_MAIN_GFX_PTRS_LO = 0xF980
local SPRITE_MAIN_GFX_PTRS_HI = 0xFA80
local SPRITE_FRAME_GFX_PTRS_LO = 0x8100
local SPRITE_FRAME_GFX_PTRS_HI = 0x8300
local SPRITE_FRAME_NUM = 0x06A0
local SPRITE_FRAME_POS_OFFSET_PTRS_LO = 0x8400
local SPRITE_FRAME_POS_OFFSET_PTRS_HI = 0x8500
local TILE_OFFSET_SUBTRACTION_TABLE = 0x8600

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

local function getPtr(hiTable, loTable, index)
    return bit.bor(bit.lshift(memory.readbyte(hiTable + index), 8), memory.readbyte(loTable + index))
end

local function drawGfx(gfxPtr, spriteSlot, spriteFlags, attributeOverride)

    if debugMode then print(string.format("GFX ROUTINE: $%04X - %02X, %02X", gfxPtr, spriteSlot, attributeOverride)) end

    local length = memory.readbyte(gfxPtr)
    local posSeq = memory.readbyte(gfxPtr + 1)
    local posPtr = getPtr(SPRITE_FRAME_POS_OFFSET_PTRS_HI, SPRITE_FRAME_POS_OFFSET_PTRS_LO, posSeq)
    local baseX = memory.readbyte(0x0460 + spriteSlot) - memory.readbyte(0x1F) -- world pos - scroll
    local baseY = memory.readbyte(0x04A0 + spriteSlot)
    local spriteFlip = bit.band(spriteFlags, 0x40)
    local j = 2
    
    for i = 1, length do
        if debugMode then print(string.format("Tile #%d: %02X, %02X, %02X, %02X", i - 1, memory.readbyte(gfxPtr + j), memory.readbyte(posPtr + j + 1), memory.readbyte(posPtr + j), memory.readbyte(gfxPtr + j + 1))) end
        local tile = memory.readbyte(gfxPtr + j)
        local y = bit.band(memory.readbyte(posPtr + j) + baseY, 0xFF) -- 8 bit addition
        j = j + 1
        local attributes = memory.readbyte(gfxPtr + j)
        if debugMode then print(string.format("base gfx attributes: %02X", attributes)) end
        if attributeOverride ~= 0 then
            if debugMode then print(string.format("overriding with %02X", attributeOverride)) end
            local newAttr = bit.bor(bit.band(attributes, 0xF0), attributeOverride)
            if newAttr ~= 0 then
                attributes = newAttr
            end
        end
        if debugMode then print(string.format("merged attributes: %02X", attributes)) end
        -- Flip tile if gfx data says tile is flipped.
        attributes = bit.bxor(spriteFlip, attributes)
        local xOffset = memory.readbyte(posPtr + j)
        if debugMode then print(string.format("sprite flip: %02X. new attr: %02x", spriteFlip, attributes)) end
        if debugMode then print(string.format("base x offset: %02X", xOffset)) end
        if spriteFlip ~= 0 then
            -- Flipped draw (need to compute alternate X coord)
            -- This table just represents the operation -(x + 8), but might as well do it authentically.
            xOffset = memory.readbyte(TILE_OFFSET_SUBTRACTION_TABLE + xOffset)
        end
        
        if debugMode then print(string.format("x offset: %02X", xOffset)) end
        -- 8-bit addition
        local x = baseX + xOffset
        if debugMode then print(string.format("x: %02X", x)) end
        local carry = x > 0xFF
        if debugMode then print("carry: "..tostring(carry)) end
        x = bit.band(x, 0xFF) 
        if debugMode then print(string.format("band x: %02X", x)) end
        --if carry ~= (xOffset >= 0x80) then
            -- No overflow; tile onscreen
            if debugMode then print(string.format("Draw tile: %02X, %02X, %02X, %02X", y, attributes, tile, x)) end
            tdraw.bufferDraw(y, attributes, tile, x)
        --else
            -- Overflow; tile offscreen
        --end
        j = j + 1
    end
end

local function drawPlayerSprite(index)

end

local function drawEnemySprite(slot)

    -- if slot ~= 0x1E then return end

    local flags = memory.readbyte(SPRITE_FLAGS + slot)
    if debugMode then  print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    if flags < 0x80 then return end
    
    if debugMode then print("(alive)") end
    
    -- might pass some of these as params
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(SPRITE_MAIN_GFX_PTRS_HI, SPRITE_MAIN_GFX_PTRS_LO, id)
    local frame = memory.readbyte(SPRITE_FRAME_NUM + slot)
    local frameId = memory.readbyte(ptr + frame + 2)
    
    if debugMode then print(string.format("main gfx ptr: $%04X", ptr)) end
    if debugMode then print(string.format("draw frame %02X", frameId)) end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if frameId == 0 then return end
    
    if bit.band(flags, 0x20) ~= 0 then return end
    if debugMode then print("(visible)") end
    
    ptr = getPtr(SPRITE_FRAME_GFX_PTRS_HI, SPRITE_FRAME_GFX_PTRS_LO, frameId)
    if debugMode then print(string.format("draw ptr: $%04X", ptr)) end
    local attributeOverride = memory.readbyte(0x0100 + slot)
    drawGfx(ptr, slot, flags, attributeOverride)
end

local normalGfx = false
local frozenGfx = false
local pauseMenuGfx = false
local pauseMenuInit = false

local function drawSpritesNormal()

    -- Need bank A loaded! Do this on the exec callback?

    tdraw.clearBuffer()
    
    local frameCount = memory.readbyte(0x1C)
    
    if frameCount % 2 == 0 then
        -- Draw sprites forwards
        for i = 0, 0xF do
            drawPlayerSprite(i)
        end
        for i = 0x10, 0x1F do
            drawEnemySprite(i)
        end
        drawEnergyBars()
    else
        -- Draw sprites backwards
        drawEnergyBars()
        for i = 0x1F, 0x10, -1 do
            drawEnemySprite(i)
        end
        for i = 0xF, 0, -1 do
            drawPlayerSprite(i)
        end
    end

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
        -- drawSpritesNormal()
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
    -- debugger.hitbreakpoint()
    local status, err = pcall(drawSpritesNormal)
    if not status then
        print(string.format("Error! %s", err))
    end
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
function getBank()
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
