require "ffix" -- Fixes args to be standard table instead of a string and adds \n support to print (yes, really).
local tdraw = require("tiledraw")
local argparse = require "argparse"

local parser = argparse()
    :help_max_width(900)

parser:option "--order"
    :choices {"canonical", "health-bars-in-front"}
    :default "health-bars-in-front" -- Let the user pass a permutation? o_o PhE
    :description "Sprite drawing order"
    
parser:flag "--debug"
    :description "Enable debug mode. Offset draws and print LOTS of info!"
parser:flag "--alternating"
    :description "Alternate drawing order every frame"

-- Janky custom --help because we want to return from this script, not exit the emulator entirely (which os.exit does for some reason)
-- Add to ffix?
local gotHelp = false
parser:flag "-h --help"
    :hidden(true)
    :action(function(args)
        print(parser:get_help())
        gotHelp = true
    end)

local success, result = parser:pparse()
local args

if gotHelp then return end

if not success then
    print(result.."\n")
    print(parser:get_help())
    return
else
    args = result
    print(tostring(args))
end

local debugMode = args.debug

-- TODO: no draw and re enable sprites when panning backwards
-- turn sprites back on on exit

-- For Mega Man 2, most of these addresses probably need to be adjusted.

local HEALTH_BAR_Y_TABLE = 0xCFE2
local HEALTH_BAR_TILES = 0xCFE9

local SPRITE_FLAGS = 0x0420
local SPRITE_IDS = 0x0400
local SPRITE_CEL_NUMS = 0x06A0

local ENEMY_MAIN_GFX_PTRS_LO = 0xF980
local ENEMY_MAIN_GFX_PTRS_HI = 0xFA80
local ENEMY_CEL_PTRS_LO = 0x8100
local ENEMY_CEL_PTRS_HI = 0x8300

local PLAYER_MAIN_GFX_PTRS_LO = 0xF900
local PLAYER_MAIN_GFX_PTRS_HI = 0xFA00
local PLAYER_FRAME_GFX_PTRS_LO = 0x8000
local PLAYER_FRAME_GFX_PTRS_HI = 0x8200

local SPRITE_CEL_POS_PATTERN_PTRS_LO = 0x8400
local SPRITE_CEL_POS_PATTERN_PTRS_HI = 0x8500
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
    local posPtr = getPtr(SPRITE_CEL_POS_PATTERN_PTRS_HI, SPRITE_CEL_POS_PATTERN_PTRS_LO, posSeq)
    local baseX = bit.band(memory.readbyte(0x0460 + spriteSlot) - memory.readbyte(0x1F), 0xFF) -- world pos - scroll
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
        if memory.readbyte(0x2A) == 1 then
            attributes = bit.bor(attributes, 0x20)
        end
        if debugMode then print(string.format("merged attributes: %02X", attributes)) end
        -- Flip tile if gfx data says tile is flipped.
        attributes = bit.bxor(spriteFlip, attributes)
        local xOffset = memory.readbyte(posPtr + j)
        if debugMode then print(string.format("sprite flip: %02X. new attr: %02x", spriteFlip, attributes)) end
        if debugMode then print(string.format("base x offset: %02X", xOffset)) end
        if debugMode then print(string.format("pos x: %02X", baseX)) end
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
        if carry == (xOffset >= 0x80) then
            -- No overflow; tile onscreen
            if debugMode then print(string.format("Draw tile: %02X, %02X, %02X, %02X", y, attributes, tile, x)) end
            tdraw.bufferDraw(y, attributes, tile, x)
        else
            -- Overflow; tile offscreen
        end
        j = j + 1
    end
end

local function drawPlayerSprite(slot)
    
    local flags = memory.readbyte(SPRITE_FLAGS + slot)
    
    if flags < 0x80 then return end
    if debugMode then  print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(PLAYER_MAIN_GFX_PTRS_HI, PLAYER_MAIN_GFX_PTRS_LO, id)
    local frame = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local frameId = memory.readbyte(ptr + frame + 2)
    
    if debugMode then print(string.format("main gfx ptr: $%04X", ptr)) end
    if debugMode then print(string.format("draw frame %02X", frameId)) end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if frameId == 0 then return end
    
    -- Special cases for Mega Man and bosses
    if slot == 0 then
        -- Mega Man
        local iFrames = memory.readbyte(0x4B)
        if iFrames ~= 0 then
            -- Flicker Mega Man on and off every 2 frames
            local frameCount = memory.readbyte(0x1C)
            if bit.band(frameCount, 2) ~= 0 then
                return
            end
        end
        -- Don't render Mega Man if he's off screen
        local offscreenFlag = memory.readbyte(0xF9)
        if offscreenFlag ~= 0 then
            return
        end
    elseif slot == 1 then
        -- Boss
        local iFrames = memory.readbyte(0x05A8)
        if iFrames ~= 0 then
            -- Flicker boss on and off every 2 frames
            local frameCount = memory.readbyte(0x1C)
            if bit.band(frameCount, 2) == 0 then -- Double check this logic.
                frameId = 0x18 -- Crash star for blinking invincibility
            end
        end
    end
    
    ptr = getPtr(PLAYER_FRAME_GFX_PTRS_HI, PLAYER_FRAME_GFX_PTRS_LO, frameId)
    if debugMode then print(string.format("draw ptr: $%04X", ptr)) end
    drawGfx(ptr, slot, flags, 0)
    
end

local function drawEnemySprite(slot)
    
    local flags = memory.readbyte(SPRITE_FLAGS + slot)
    
    if flags < 0x80 then return end
    if debugMode then  print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    -- might pass some of these as params
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(ENEMY_MAIN_GFX_PTRS_HI, ENEMY_MAIN_GFX_PTRS_LO, id)
    local frame = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local frameId = memory.readbyte(ptr + frame + 2)
    
    if debugMode then print(string.format("main gfx ptr: $%04X", ptr)) end
    if debugMode then print(string.format("draw frame %02X", frameId)) end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if frameId == 0 then return end
    
    if bit.band(flags, 0x20) ~= 0 then return end
    if debugMode then print("(visible)") end
    
    ptr = getPtr(ENEMY_CEL_PTRS_HI, ENEMY_CEL_PTRS_LO, frameId)
    if debugMode then print(string.format("draw ptr: $%04X", ptr)) end
    local attributeOverride = memory.readbyte(0x0100 + slot)
    drawGfx(ptr, slot, flags, attributeOverride)
end

local normalGfx = false
local frozenGfx = false
local pauseMenuGfx = false
local pauseMenuInit = false

local function drawSpritesNormal()

    --tdraw.clearBuffer()
    emu.setrenderplanes(false, true) -- Disable emu sprite rendering to replace it with out own
    
    local frameCount = memory.readbyte(0x1C)
    
    if frameCount % 2 == 0 or canonicalOrder then
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
    --tdraw.clearBuffer()
    -- I think this works because the frozen draw routine is the same code as the regular draw routine, but animation timers aren't incremented.
    -- This script is only interested in reading whatever animation data the game is producing, so it has no need for that information.
    drawSpritesNormal() -- TODO: This will probably break when I implement drawPlayerSprite
end

local function drawSpritesPauseMenu()
    --tdraw.clearBuffer()
    emu.setrenderplanes(true, true) -- Re-enable sprites. No need to simulate the pause menu graphics.
end

local prevGameState = memory.readbyte(0x01FE)

local function drawSpritesMenuPopup()
    -- This routine is reused by menu popup and scrolling. Since I don't feel like reverse engineering that right now,
    -- I'm using hacky gamestate jank until I do.
    if gameState ~= 156 and prevGameState ~= 156 then
        tdraw.clearBuffer()
        emu.setrenderplanes(true, true) -- Re-enable sprites. No need to simulate the pause menu graphics.
    end
end

-- TODO: gui.register?
local function drawSprites()
    
    prevGameState = gameState
    gameState = memory.readbyte(0x01FE)
    
    tdraw.renderBuffer()

    -- Health bar sometimes appears one frame before it's supposed to in boss fights.
    --   Has to do with that one lag frame you sometimes get. Is there another callback to look for?
    -- Objects persist during the end credits and on READY screen. Just need to do a gamestate check.
    -- When the emulator itself renders objects, we get back-prioity issues. Try implementing priority correctly first.
    -- Blue "Buster energy" can be seen during 1 frame of loading lag. Basically my garbage is different than their garbage.
    
    if gameState == 78 or gameState == 120 or gameState == 129 or gameState == 195 or gameState == 197 then
        if debugMode then gui.text(100, 10, "Get equipped/Castle/Death") end
        tdraw.clearBuffer()
        emu.setrenderplanes(true, true)
    elseif normalGfx then
        if debugMode then gui.text(100, 10, "Normal gfx") end
        -- drawSpritesNormal()
        normalGfx = false
    elseif frozenGfx then
        if debugMode then gui.text(100, 10, "Frozen gfx") end
        -- drawSpritesFrozen()
        frozenGfx = false
    elseif pauseMenuGfx then
        if debugMode then gui.text(100, 10, "Pause menu gfx") end
        drawSpritesPauseMenu()
        --emu.setrenderplanes(true, true)
        pauseMenuGfx = false
    elseif pauseMenuInit then
        if debugMode then gui.text(100, 10, "Menu routine") end
        drawSpritesMenuPopup()
        pauseMenuInit = false
    else
        if debugMode then gui.text(100, 10, "None") end
        -- Could try to detect the scroll init state instead of lumping it in with None
       emu.setrenderplanes(true, true) -- Re-enable sprites. No need to simulate the pause menu graphics.
    end
    
end

local function postFrame()
    
end

local function normalGfxRoutineCallback(address, bank)
    normalGfx = true
    local status, err = pcall(drawSpritesNormal)
    if not status then
        print(string.format("Error! %s", err))
    end
end

local function timeFrozenGfxRoutineCallback()
    local status, err = pcall(drawSpritesFrozen)
    --emu.setrenderplanes(false, true)
    if not status then
        print(string.format("Error! %s", err))
    end
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
