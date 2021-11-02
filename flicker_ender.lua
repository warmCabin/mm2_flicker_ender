require "ffix" -- Fixes args to be standard table instead of a string and adds \n support to print (yes, really).
local tdraw = require("tiledraw")
local argparse = require "argparse"

local parser = argparse()

parser:option "--order -o"
    :choices {"canonical", "health-bars-in-front"}
    :default "health-bars-in-front" -- Let the user pass a permutation? o_o PhE
    :description "Sprite drawing order"
    
parser:flag "--alternating -a"
    :description "Alternate drawing order every frame"
    
parser:flag "--debug -d"
    :description "Enable debug mode. Offset rendering and draw some info to the screen"
parser:flag "--verbose -v"
    :description "Enable verbose printing. WARNING: very slow!"

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
end

debugMode = args.debug

-- TODO: no draw and re enable sprites when panning backwards
-- turn sprites back on on exit

-- For Mega Man 2, most of these addresses probably need to be adjusted.

local HEALTH_BAR_Y_TABLE = 0xCFE2
local HEALTH_BAR_TILES = 0xCFE9

local SPRITE_FLAGS = 0x0420
local SPRITE_IDS = 0x0400
local SPRITE_CEL_NUMS = 0x06A0

local ENEMY_ANIM_PTRS_LO = 0xF980
local ENEMY_ANIM_PTRS_HI = 0xFA80
local ENEMY_CEL_PTRS_LO = 0x8100
local ENEMY_CEL_PTRS_HI = 0x8300

local PLAYER_ANIM_PTRS_LO = 0xF900
local PLAYER_ANIM_PTRS_HI = 0xFA00
local PLAYER_CEL_PTRS_LO = 0x8000
local PLAYER_CEL_PTRS_HI = 0x8200

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

local function drawCel(celPtr, spriteSlot, spriteFlags, attributeOverride)

    if args.verbose then print(string.format("GFX ROUTINE: $%04X - %02X, %02X", celPtr, spriteSlot, attributeOverride)) end

    local length = memory.readbyte(celPtr)
    local posSeq = memory.readbyte(celPtr + 1)
    local posPtr = getPtr(SPRITE_CEL_POS_PATTERN_PTRS_HI, SPRITE_CEL_POS_PATTERN_PTRS_LO, posSeq)
    local baseX = bit.band(memory.readbyte(0x0460 + spriteSlot) - memory.readbyte(0x1F), 0xFF) -- world pos - scroll
    local baseY = memory.readbyte(0x04A0 + spriteSlot)
    local spriteFlip = bit.band(spriteFlags, 0x40)
    local j = 2
    
    for i = 1, length do
        if args.verbose then print(string.format("Tile #%d: %02X, %02X, %02X, %02X", i - 1, memory.readbyte(celPtr + j), memory.readbyte(posPtr + j + 1), memory.readbyte(posPtr + j), memory.readbyte(celPtr + j + 1))) end
        local tile = memory.readbyte(celPtr + j)
        local y = bit.band(memory.readbyte(posPtr + j) + baseY, 0xFF) -- 8 bit addition
        j = j + 1
        local attributes = memory.readbyte(celPtr + j)
        if args.verbose then print(string.format("base gfx attributes: %02X", attributes)) end
        if attributeOverride ~= 0 then
            if args.verbose then print(string.format("overriding with %02X", attributeOverride)) end
            local newAttr = bit.bor(bit.band(attributes, 0xF0), attributeOverride)
            if newAttr ~= 0 then
                attributes = newAttr
            end
        end
        -- If we're on Airman's stage, set the priority bit on all sprites.
        -- Some hacks override this stage number, e.g. Rockman2Min, so get it directly from the code for maximum compatibility.
        if memory.readbyte(0x2A) == memory.readbyte(0xCCE5) then
            attributes = bit.bor(attributes, 0x20)
        end
        if args.verbose then print(string.format("merged attributes: %02X", attributes)) end
        -- Flip tile if gfx data says tile is flipped.
        attributes = bit.bxor(spriteFlip, attributes)
        local xOffset = memory.readbyte(posPtr + j)
        if args.verbose then print(string.format("sprite flip: %02X. new attr: %02x", spriteFlip, attributes)) end
        if args.verbose then print(string.format("base x offset: %02X", xOffset)) end
        if args.verbose then print(string.format("pos x: %02X", baseX)) end
        if spriteFlip ~= 0 then
            -- Flipped draw (need to compute alternate X coord)
            -- This table just represents the operation -(x + 8), but might as well do it authentically.
            xOffset = memory.readbyte(TILE_OFFSET_SUBTRACTION_TABLE + xOffset)
        end
        if args.verbose then print(string.format("x offset: %02X", xOffset)) end
        -- 8-bit addition
        local x = baseX + xOffset
        if args.verbose then print(string.format("x: %02X", x)) end
        local carry = x > 0xFF
        if args.verbose then print("carry: "..tostring(carry)) end
        x = bit.band(x, 0xFF) 
        if args.verbose then print(string.format("band x: %02X", x)) end
        if carry == (xOffset >= 0x80) then
            -- No overflow; tile onscreen
            if args.verbose then print(string.format("Draw tile: %02X, %02X, %02X, %02X", y, attributes, tile, x)) end
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
    if args.verbose then  print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(PLAYER_ANIM_PTRS_HI, PLAYER_ANIM_PTRS_LO, id)
    local celNum = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local celId = memory.readbyte(ptr + celNum + 2)
    
    if args.verbose then print(string.format("main gfx ptr: $%04X", ptr)) end
    if args.verbose then print(string.format("draw celNum %02X", celId)) end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if celId == 0 then return end
    
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
                celId = 0x18 -- Crash star for blinking invincibility
            end
        end
    end
    
    ptr = getPtr(PLAYER_CEL_PTRS_HI, PLAYER_CEL_PTRS_LO, celId)
    if args.verbose then print(string.format("draw ptr: $%04X", ptr)) end
    drawCel(ptr, slot, flags, 0)
    
end

local function drawEnemySprite(slot)
    
    local flags = memory.readbyte(SPRITE_FLAGS + slot)
    
    if flags < 0x80 then return end
    if args.verbose then print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    -- might pass some of these as params
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(ENEMY_ANIM_PTRS_HI, ENEMY_ANIM_PTRS_LO, id)
    local celNum = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local celId = memory.readbyte(ptr + celNum + 2)
    
    if args.verbose then print(string.format("main gfx ptr: $%04X", ptr)) end
    if args.verbose then print(string.format("draw celNum %02X", celId)) end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if celId == 0 then return end
    
    if bit.band(flags, 0x20) ~= 0 then return end
    if args.verbose then print("(visible)") end
    
    ptr = getPtr(ENEMY_CEL_PTRS_HI, ENEMY_CEL_PTRS_LO, celId)
    if args.verbose then print(string.format("draw ptr: $%04X", ptr)) end
    local attributeOverride = memory.readbyte(0x0100 + slot)
    drawCel(ptr, slot, flags, attributeOverride)
end

local normalGfx = false
local frozenGfx = false
local pauseMenuGfx = false
local pauseMenuInit = false

local function drawEnemySprites(forward)
    local start, stop, step
    if forward then
        start, stop, step = 0x10, 0x1F, 1
    else
        start, stop, step = 0x1F, 0x10, -1
    end
    
    for i = start, stop, step do
        drawEnemySprite(i)
    end
end

local function drawPlayerSprites(forward)
    local start, stop, step
    if forward then
        start, stop, step = 0, 0xF, 1
    else
        start, stop, step = 0xF, 0, -1
    end
    
    for i = start, stop, step do
        drawPlayerSprite(i)
    end
end

local drawFuncs
if args.order == "canonical" then
    drawFuncs = {drawPlayerSprites, drawEnemySprites, drawEnergyBars}
elseif args.order == "health-bars-in-front" then
    drawFuncs = {drawEnergyBars, drawPlayerSprites, drawEnemySprites}
else
    error("Somehow, an invalid --order option got through.")
end

local function drawSpritesNormal()

    -- tdraw.clearBuffer()
    
    -- Disable emu sprite rendering to replace it with our own, conditionally.
    -- There's a tradeoff here.
    -- Leaving actual sprite rendering enabled causes weird interactions with
    -- back-prioity sprites (between the real ones and the flicker_ender ones).
    -- Disabling it screws screws with TASEditor panning, leaving us with no
    -- actual sprites or flicker_ender sprites to look at.
    -- This issue stems from the usage of emu.getscreenpixel in tiledraw.lua,
    -- so if I implement a nametable-inspecting getbgpixel function, it will
    -- go away!
    if not debugMode and not taseditor.engaged() then emu.setrenderplanes(false, true) end
    
    local frameCount = memory.readbyte(0x1C)
    if not args.alternating or frameCount % 2 == 0 then
        -- Draw sprites forwards
        for _, func in ipairs(drawFuncs) do
            func(true)
        end
    else
         -- Draw sprites backwards
         for i = #drawFuncs, 1, -1 do
            drawFuncs[i](false)
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
    tdraw.clearBuffer() -- Clear OAM so stale graphics don't show during menu popup
    emu.setrenderplanes(true, true) -- Re-enable sprites. No need to simulate the pause menu graphics.
end

local prevFrameCount = 0

-- TODO: emu.registerbefore? Might make the tdraw buffering a little less contrived.
local function drawSprites()
    
    prevGameState = gameState
    gameState = memory.readbyte(0x01FE)
    
    -- Check if panning backwards, mainly to support TASEditor.
    if emu.framecount() <= prevFrameCount then
        tdraw.clearBuffer()
        -- Workaround to clear FCEUX's buffer so previous flicker_ender frames don't persist.
        -- No relation to the color "clear"!
        gui.pixel(10, 10, "clear")
        prevFrameCount = emu.framecount()
        emu.setrenderplanes(true, true)
        return
    end
    
    prevFrameCount = emu.framecount()
    
    tdraw.renderBuffer()

    -- Health bar sometimes appears one frame before it's supposed to in boss fights.
    --   Has to do with that one lag frame you sometimes get. Is there another callback to look for?
    -- When the emulator itself renders objects, we get back-prioity issues. Try implementing priority correctly first.
    -- Blue "Buster energy" can be seen during 1 frame of loading lag. Basically my garbage is different than their garbage.
    
    if gameState == 78 or gameState == 120 or gameState == 129 or gameState == 195 or gameState == 197 or gameState == 112 or gameState == 82 then
        if debugMode then gui.text(100, 10, "Defer to game") end
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
        if debugMode then gui.text(100, 10, "Pause menu init") end
        drawSpritesMenuPopup()
        pauseMenuInit = false
    else
        if debugMode then gui.text(100, 10, "None") end
        -- Could try to detect the scroll init state instead of lumping it in with None
       emu.setrenderplanes(true, true) -- Re-enable sprites. No need to simulate the pause menu graphics.
    end
    
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

emu.registerafter(drawSprites)

registerAddressBanked(0xCC8B, 0xF, normalGfxRoutineCallback)
registerAddressBanked(0xCD02, 0xF, timeFrozenGfxRoutineCallback)
registerAddressBanked(0x9396, 0xD, pauseMenuGfxRoutineCallback)
registerAddressBanked(0x90EF, 0xD, menuInitRoutineCallback) -- This is just the address where it clears OAM. More analysis needed.

memory.registerwrite(0x2000, 7, ppuRegCallback)
