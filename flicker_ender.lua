require "ffix" -- Fixes args to be standard table instead of a string and adds \n support to print (yes, really).
local tdraw = require("tiledraw")
local argparse = require "argparse"

local parser = argparse()

-- Let the user pass a permutation? o_o PhE
parser:option "--order -o"
    :choices {"canonical", "recommended"}
    :description "Sprite drawing order. canonical = what the game does. recommended = tweaks to fix certain overlapping issues. If unspecified, will be chosen based on shuffle."
    
parser:option "--shuffle -s"
    :choices {"alternating", "cyclic", "none"}
    :default "alternating"
    :description "What type of sprite shuffling to use. The real game code uses alternating."
    
parser:option "--oam-limit -l"
    :convert(function(str)
        local n = tonumber(str)
        if not n or n <= 0 or n ~= math.floor(n) then
            return nil, "num sprites be a positive integer."
        end
        return n
    end)
    :argname "<num sprites>"
    :description "Limit for the imitation OAM. Will be infinite if unspecified (recommended). 64 is the NES default. Use this if you want to make flicker worse!"
    
parser:flag "--disable-i-frame-flicker -i"
    :description("Whether Mega Man and bosses should flicker during i-frames")
parser:flag "--debug -d"
    :description "Enable debug mode. Offset rendering and draw some info to the screen"
parser:flag "--verbose -v"
    :count "0-3"
    :description "Enable verbose printing, up to 3 levels. WARNING: very slow!"

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

-- args prost-processing
debugMode = args.debug
local drawOrder = args.order or (args.shuffle == "none" and "recommended" or "canonical")

if args.oam_limit then
    tdraw.setOamLimit(args.oam_limit)
end

if args.verbose >= 1 then print(string.format("shuffle: %s, drawOrder: %s", args.shuffle, drawOrder)) end

-- For Mega Man 2, most of these addresses probably need to be adjusted. Especially the callbacks at the bottom of the script.

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
-- then monitor whatever it tries to write. But that would alter game function. For instance, this value is used to
-- set up the range of sprites that need to have their priority bit set in Airman's stage.

local function drawEnergyBar(energy, x, palette)
    for i = 6, 0, -1 do
        local y = memory.readbyte(HEALTH_BAR_Y_TABLE + i)
        local tile
        if energy < 4 then
            tile = memory.readbyte(HEALTH_BAR_TILES + energy)
            energy = 0
        else
            tile = 0x87 -- TODO: Grab this from ROM
            energy = energy - 4
        end
        
        tdraw.bufferDraw(y, palette, tile, x)
        
    end
end

-- TODO: Grab X positions and boss palettes from ROM to support changes in hacks
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
        -- Most bosses use palette 3 for their health bars. But for Mecha Dragon and Alien (bosses 8 and D)
        -- that would look really weird, mostly because there's no black outline color.
        -- So these two bosses use palette 1, the ubiquitous face colors.
        local palette = (bossIndex == 8 or bossIndex == 0xD) and 1 or 3
        drawEnergyBar(bossHealth, 0x28, palette)
    end
    
end

local function getPtr(hiTable, loTable, index)
    return bit.bor(bit.lshift(memory.readbyte(hiTable + index), 8), memory.readbyte(loTable + index))
end

--[[
  Note: attributeOverride should really be named paletteOverride. I overestimated its usefulness when I first discovered it.
    Its intended design is: if it's nonzero (1-3), apply that palette to all tiles in the cel. It was exclusively used to turn enemies white (palette 1)
    for 1 frame when you shoot them. In fact, it even doubles as an i-frames indicator.
    
    Notably, you can't override things to use palette 0, because 0 means no override. Except you can abuse the data a little bit. If you set one of the unused bits to 1,
    the code will accept the override even if the palette is 0, and the unused bit will be safely ignored by the PPU.
    
    You can also override the priority bit to 1, but not override it to 0 if it was already 1.
    You can do the same to the X and Y flip bits to garble the graphics in a fun way.
    But you inadvertantly apply a palette override when you do either of these things, so just don't.
    
    Makes me wonder how they accomplished the sprite priority effects in the first game.
]]
local function drawCel(celPtr, spriteSlot, spriteFlags, attributeOverride)

    if args.verbose >= 2 then print(string.format("GFX ROUTINE: $%04X - %02X, %02X", celPtr, spriteSlot, attributeOverride)) end

    local length = memory.readbyte(celPtr)
    local posSeq = memory.readbyte(celPtr + 1)
    local posPtr = getPtr(SPRITE_CEL_POS_PATTERN_PTRS_HI, SPRITE_CEL_POS_PATTERN_PTRS_LO, posSeq)
    local baseX = bit.band(memory.readbyte(0x0460 + spriteSlot) - memory.readbyte(0x1F), 0xFF) -- world pos - scroll
    local baseY = memory.readbyte(0x04A0 + spriteSlot)
    local spriteFlip = bit.band(spriteFlags, 0x40)
    local j = 2
    
    for i = 1, length do
        if args.verbose >= 3 then print(string.format("Tile #%d: %02X, %02X, %02X, %02X", i - 1, memory.readbyte(celPtr + j), memory.readbyte(posPtr + j + 1), memory.readbyte(posPtr + j), memory.readbyte(celPtr + j + 1))) end
        local tile = memory.readbyte(celPtr + j)
        local y = bit.band(memory.readbyte(posPtr + j) + baseY, 0xFF) -- 8 bit addition
        j = j + 1
        local attributes = memory.readbyte(celPtr + j)
        if args.verbose >= 3 then print(string.format("base gfx attributes: %02X", attributes)) end
        if attributeOverride ~= 0 then
            if args.verbose >= 3 then print(string.format("overriding with %02X", attributeOverride)) end
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
        if args.verbose >= 3 then print(string.format("merged attributes: %02X", attributes)) end
        -- Flip tile if gfx data says tile is flipped.
        attributes = bit.bxor(spriteFlip, attributes)
        local xOffset = memory.readbyte(posPtr + j)
        if args.verbose >= 3 then
            print(string.format("sprite flip: %02X. new attr: %02x", spriteFlip, attributes))
            print(string.format("base x offset: %02X", xOffset))
            print(string.format("pos x: %02X", baseX))
        end
        if spriteFlip ~= 0 then
            -- Flipped draw (need to compute alternate X coord)
            -- This table just represents the operation -(x + 8), but might as well do it authentically.
            xOffset = memory.readbyte(TILE_OFFSET_SUBTRACTION_TABLE + xOffset)
        end
        if args.verbose >= 3 then print(string.format("x offset: %02X", xOffset)) end
        -- 8-bit addition
        local x = baseX + xOffset
        if args.verbose >= 3 then print(string.format("x: %02X", x)) end
        local carry = x > 0xFF
        if args.verbose >= 3 then print("carry: "..tostring(carry)) end
        x = bit.band(x, 0xFF) 
        if args.verbose >= 3 then print(string.format("band x: %02X", x)) end
        if carry == (xOffset >= 0x80) then
            -- No overflow; tile onscreen
            if args.verbose >= 3 then print(string.format("Draw tile: %02X, %02X, %02X, %02X", y, attributes, tile, x)) end
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
    if args.verbose >= 1 then print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(PLAYER_ANIM_PTRS_HI, PLAYER_ANIM_PTRS_LO, id)
    local celNum = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local celId = memory.readbyte(ptr + celNum + 2)
    
    if args.verbose >= 1 then
        print(string.format("main anim ptr: $%04X", ptr))
        print(string.format("draw celId %02X", celId))
    end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if celId == 0 then return end
    
    -- Special cases for Mega Man and bosses
    if slot == 0 then
        -- Mega Man
        local iFrames = memory.readbyte(0x4B)
        if iFrames ~= 0 then
            local frameCount = memory.readbyte(0x1C)
            if args.disable_i_frame_flicker then
                -- The knockback animation has a crash star as one of its cels. To disable this, just set it back to the regular knockback pose.
                if celId == 0x18 then
                    celId = 0x7
                end
            elseif bit.band(frameCount, 2) ~= 0 then
                -- Flicker Mega Man on and off every 2 frames
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
            local frameCount = memory.readbyte(0x1C)
            if not args.disable_i_frame_flicker and bit.band(frameCount, 2) == 0 then
                -- Bosses don't have a knockback animation. Instead, their animation cel is overridden with a crash star 2 out of every 4 frames.
                celId = 0x18
            end
        end
    end
    
    ptr = getPtr(PLAYER_CEL_PTRS_HI, PLAYER_CEL_PTRS_LO, celId)
    if args.verbose >= 1 then print(string.format("cel ptr: $%04X", ptr)) end
    drawCel(ptr, slot, flags, 0) -- There are no attribute overrides for player sprites.
    
end

local function drawEnemySprite(slot)
    
    local flags = memory.readbyte(SPRITE_FLAGS + slot)
    
    if flags < 0x80 then return end
    if args.verbose >= 1 then print(string.format("DRAWING SLOT %02X (%02X)", slot, flags)) end
    
    -- might pass some of these as params
    local id = memory.readbyte(SPRITE_IDS + slot)
    local ptr = getPtr(ENEMY_ANIM_PTRS_HI, ENEMY_ANIM_PTRS_LO, id)
    local celNum = memory.readbyte(SPRITE_CEL_NUMS + slot)
    local celId = memory.readbyte(ptr + celNum + 2)
    
    if args.verbose >= 1 then
        print(string.format("main anim ptr: $%04X", ptr))
        print(string.format("draw celId %02X", celId))
    end
    
    -- There are some details here in the real code concerning animation timers which we don't care about.
    
    if celId == 0 then return end
    
    if bit.band(flags, 0x20) ~= 0 then return end
    if args.verbose >= 1 then print("(visible)") end
    
    ptr = getPtr(ENEMY_CEL_PTRS_HI, ENEMY_CEL_PTRS_LO, celId)
    if args.verbose >= 1 then print(string.format("cel ptr: $%04X", ptr)) end
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

local playerOrder

local function drawPlayerSprites(forward)
    local start, stop, step
    if forward then
        start, stop, step = 1, 16, 1
    else
        start, stop, step = 16, 1, -1
        if args.order == "recommended" then
            -- Make sure Mega Man and the boss aren't redrawn.
            -- Relies on specific knowledge of the recommended playerOrder list...
            start = 15
            stop = 2
        end
    end
    
    for i = start, stop, step do
        local slot = playerOrder[i]
        drawPlayerSprite(slot)
    end
end

local function drawPlayerSpritesR(shuffler)
    for i = 0, 0xF do
        local slot = (i + shuffler) % 0x10
        drawPlayerSprite(slot)
    end
end

local function drawEnemySpritesR(shuffler)
    for i = 0x10, 0x1F do
        local slot = (i - 0x10 + shuffler) % 0x10 + 0x10
        drawEnemySprite(slot)
    end
end

--[[
    For a fixed drawing order, you would want to set certain rules and priorities for what draws on top of what.
    Due to sprite flicker, this is not a problem the devs had to solve back in the day. My recommended drawing order
    generally does what you'd expect (health bars obscure everything, Mega Man always on top, boss has enemy priority), 
    but can still lead to annoying cases, e.g. a power-up obscured by a bullet. Maybe I'm overthinking this and a
    slot-based order is exactly what they would have done!
]]
local drawFuncs
if drawOrder == "canonical" then
    drawFuncs = {drawPlayerSprites, drawEnemySprites, drawEnergyBars}
    playerOrder = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF}
elseif drawOrder == "recommended" then
    drawFuncs = {drawEnergyBars, drawPlayerSprites, drawEnemySprites}
    playerOrder = {0, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1} -- TODO: Put Mega Man's projectiles on top of him?
else
    error("Somehow, an invalid --order option got through.")
end

local shuffler = 0

-- This is how the game Recca does it.
local function drawSpritesReccaStyle()

    local frameCount = memory.readbyte(0x1C)
    local x = bit.band(frameCount, 3)
    
    if x == 0 then
        drawEnergyBars()
        drawPlayerSpritesR(shuffler)
        drawEnemySpritesR(shuffler)
    elseif x == 1 then
        drawPlayerSpritesR(shuffler)
        drawEnemySpritesR(shuffler)
        drawEnergyBars()
    elseif x == 2 then
        drawPlayerSpritesR(shuffler)
        drawEnergyBars()
        drawEnemySpritesR(shuffler)
    elseif x == 3 then
        drawEnemySpritesR(shuffler)
        drawPlayerSpritesR(shuffler)
        drawEnergyBars()
    end
    
    -- Incrementing by anything less than 4 (or by a number that doesn't divide 16) is a bit of an eyesore.
    shuffler = (shuffler + 4) % 0x10
    
end

local function drawSpritesNormal()

    if args.verbose >= 1 then print(string.format("=== %d - Drawing sprites ===", emu.framecount())) end

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
    
    -- Alternating shuffle will make two or three things flicker on and off when you start to go over.
    -- It's good when you're a bit over the limit.
    -- Cyclic shuffle will give everything its turn flicked off.
    -- It's good when you're WAY over the limit.
    -- The order argument is mostly irrelevant to this technique, so just ignore it.
    if args.shuffle == "cyclic" then
        drawSpritesReccaStyle()
        return
    end
    
    local frameCount = memory.readbyte(0x1C)
    if args.shuffle == "none" or frameCount % 2 == 0 then
        -- Draw sprites forwards
        for _, func in ipairs(drawFuncs) do
            func(true)
        end
    else
        -- Draw sprites backwards
        if args.order == "recommended" then
           drawPlayerSprite(0) -- always draw Mega Man on top
           drawPlayerSprite(1) -- Then draw the boss
           -- The health bar still alternates priority with them, though. Is that a good thing? I can't decide...
        end
        for i = #drawFuncs, 1, -1 do
            drawFuncs[i](false)
        end
    end
    
end

local function drawSpritesFrozen()
    --tdraw.clearBuffer()
    -- This works because the frozen draw routine is the same code as the regular draw routine, but animation timers aren't incremented.
    -- This script is only interested in reading whatever animation data the game is producing, so it has no need for that information.
    drawSpritesNormal()
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

local function drawSprites()
    
    prevGameState = gameState
    gameState = memory.readbyte(0x01FE)
    
    -- Check if panning backwards, mainly to support TASEditor.
    -- TODO: if emu.framecount() ~= prevFrameCount + 1, to also check for forward jumps?
    if emu.framecount() <= prevFrameCount then
        tdraw.clearBuffer()
        -- Workaround to clear FCEUX's framebuffer so previous flicker_ender frames don't persist.
        -- "clear" doesn't clear the buffer, it's just a clear pixel. This couldn't be more clear.
        gui.pixel(10, 10, "clear")
        prevFrameCount = emu.framecount()
        emu.setrenderplanes(true, true)
        return
    end
    
    prevFrameCount = emu.framecount()
    
    -- Render buffer every frame. This corresponds to what the PPU should have,
    -- which is managed by flushing the buffer in the OAMDMA callback.
    tdraw.renderBuffer()

    -- When the emulator itself renders objects, we get back-prioity issues. Try implementing priority correctly first.
    
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
        -- No recognized drawing routine was called. Re-enable emulator sprites just in case.
        -- Could try to detect the scroll init state instead of lumping it in with None
       emu.setrenderplanes(true, true)
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
    if args.verbose >= 3 then print(string.format("Wrote to $%04X: #$%02X", address, value)) end
    if address == 0x2000 then
        tdraw.updatePpuCtrl(value)
    elseif address == 0x2001 then
        tdraw.updatePpuMask(value)
    end
end

local function oamDmaCallback()
    local status, err = pcall(tdraw.flushBuffer)
    if not status then
        print(string.format("Error! %s", err))
    end
end

-- This is EXTREMELY Mega Man 2 specific, sadly. I happen to know that it uses the MMC1 mode
-- that always maps F to $C000 - $FFFF and swaps 0 - E into $8000 - $BFFF. I also happen to know
-- that it uses $29 as an in-memory mirror for the current low-address bank number.
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
registerAddressBanked(0x90EF, 0xD, menuInitRoutineCallback) -- Just after OAM has been cleared for the pause menu.
registerAddressBanked(0xD016, 0xF, oamDmaCallback) -- Just when the NMI handler is initiating DMA.

memory.registerwrite(0x2000, 7, ppuRegCallback)

-- Restore drawing to normal when exiting script
emu.registerexit(function()
    emu.setrenderplanes(true, true)
end)

local verbs = {"Ending", "Putting an end to", "Removing", "Obliterating", "Smashing", "Destroying", "Murdering", "Killing", "Annihilating", "Decimating", "Unflicking", "Cancelling", "Defeating", "Hey, I actually prefer", "Deleting", "Forcibly ceasing"}
print(verbs[math.random(#verbs)].." flicker...")
