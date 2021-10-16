local bit = require("bit")

local mod = {}

local patternTable = 0
local spriteSize = 0 -- 0 == 8x8

local showLeftmost = true
local showSprites = true
local grayscale = false

local charMap = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'}

function mod.toString(num, base, length)
    
    base = base or 10
    
    if not num or base < 2 or base > 16 then return end
    
    if num == 0 then return ("0"):rep(length) end
    
    if num < 0 then return "-"..toString(-num, base, length) end
    
    local ret = ""

    while num > 0 do
        ret = charMap[num % base + 1]..ret
        num = math.floor(num / base)
    end
    
    if length then ret = (("0"):rep(length - #ret))..ret end
    
    return ret
end

local function mergePlanes(plane0, plane1)
    local str = ""
    for i = 7, 0, -1 do
        local mask = bit.lshift(1, i)
        local bit0 = bit.rshift(bit.band(plane0, mask), i)
        local bit1 = bit.rshift(bit.band(plane1, mask), i)
        local sum = bit.bor(bit0, bit.lshift(bit1, 1))
        -- if sum ~= 0 then sum = 4 - sum end
        str = str..sum
    end
    return str
end

function mod.getTileData(patternTable, tile)
    local baseAddr = bit.lshift(patternTable, 12) + bit.lshift(tile, 4)
    -- gui.text(10, 10, string.format("tile %02X: $%04X", tile, baseAddr))
    local ret = {}
    
    for i = 0, 7 do 
        local plane0 = ppu.readbyte(baseAddr + i)
        local plane1 = ppu.readbyte(baseAddr + 8 + i)
        -- print(string.format("%04X", baseAddr + i))
        -- print(string.format("%04X", baseAddr + i + 8))
        --gui.text(10, 20 + 20 * i, toString(plane0, 2, 8))
        --gui.text(10, 30 + 20 * i, toString(plane1, 2, 8))
        -- gui.text(80, 20 + 10 * i, mergePlanes(plane0, plane1))
        ret[i] = mergePlanes(plane0, plane1)
    end
    
    return ret
end

local function getColor(paletteIndex)
    -- print(string.format("getColor: %02X", paletteIndex))
    local color = ppu.readbyte(0x3F00 + paletteIndex)
    if grayscale then color = bit.band(color, 0x30) end
    --if paletteIndex ~= 0x11 then
     --   gui.text(80, 100, string.format("getColor: %02X -> %02X", paletteIndex, color))
    --end
    return string.format("P%02X", color)
end

local function shouldDraw(x, y, c, attributes)
    
    -- Is pixel on screen? gui.pixel will have a conniption if not.
    if y < 0 or y >= 240 or x < 0 or x >= 256 then
        return false
    end
    
    -- Color 0 is transparent
    if c == "0" then return false end
    
    if not showLeftmost and x < 8 then return false end
    
    -- Regardless of priority bit, return true.
    -- That logic is handled in drawPixel by picking the screen color instead of the sprite pixel color.
    return true
end

local function drawPixel(x, y, paletteIndex, attributes)
    local color = getColor(paletteIndex)
    local _, _, _, screenColor = emu.getscreenpixel(x, y, false)
    -- Check if pixel should be behind the background.
    -- This isn't perfect. Opaque BG pixels can match the global backdrop color, but they should still count as opaque.
    if bit.band(attributes, 0x20) ~= 0 and screenColor ~= ppu.readbyte(0x3F00) then
        -- Why draw this pixel at all if it's behind the background?
        -- Because on the NES, back-priority sprites can obscure front-priority sprites, even if the background is "between" them.
        color = string.format("P%02X", screenColor)
    end
    gui.pixel(x, y, color)
end

local function drawRow(x, y, row, attributes)
    local palette = bit.band(attributes, 3)
    local flipX = bit.band(attributes, 0x40) ~= 0
    for i = 1, #row do
        local c = flipX and row:sub(#row - i + 1, #row - i + 1) or row:sub(i, i)
        if shouldDraw(x + i - 1, y, c, attributes) then
            local paletteIndex = 0x10 + palette * 4 + tonumber(c)
            -- TODO: gui.pixel seems to be slow. Buffer these into a gdstring?
            drawPixel(x + i - 1, y, paletteIndex, attributes)
        end
    end
end

-- Currently only supports 8x8 mode.
-- Priority bit is based on color rather than opacity of pixel.
-- The back-priority sprite obscurring quirk is not implemented.
-- Tint bits are not implemented--they actually affect NTSC signal generation, but FCEUX stores them in an extended palette I think.
-- Are tiles invisible when they should be?
function mod.drawTile(y, attributes, index, x)

    if not showSprites then
        return
    end

    if spriteSize == 1 then
        gui.text(30, 30, "8x16 mode is not currently supported :(")
        return
    end

    local tileData = mod.getTileData(patternTable, index)
    local flipY = bit.band(attributes, 0x80) ~= 0
    for i = 0, 7 do
        local row = flipY and tileData[7 - i] or tileData[i]
        drawRow(x, y + 1 + i, row, attributes)
    end

end

local oam = {}
local prevOam = {}

function mod.bufferDraw(y, attributes, index, x)
    -- TODO: OAM_LIMIT checks here?
    table.insert(oam, {
        y = y,
        attributes = attributes,
        index = index,
        x = x
    })
end

function mod.clearBuffer()
    oam = {}
    prevOam = {}
end

-- With this nonsense in place, you can observe the exact flicker as if you had "Allow more than 8 sprites per scanline" checked.
-- Need to make this override canonical order (that's a caller problem, not tiledraw's problem!).
-- TODO: provide an API to set this
local OAM_LIMIT = 32000

function mod.renderBuffer()
    local offset = debugMode and 0 or 0
    -- Draw in reverse order because that's how the NES priotizes sprites
    local count = 0
    for i = #prevOam, 1, -1 do
        local entry = prevOam[i]
        mod.drawTile(entry.y + offset, entry.attributes, entry.index, entry.x + offset)
        count = count + 1
        if count == OAM_LIMIT then break end
    end
    if debugMode then gui.text(10, 10, #prevOam, #prevOam > 64 and "red" or "white") end
    if #oam ~= 0 then
        prevOam = oam
        oam = {}
    end
end

function mod.updatePpuCtrl(value)
    patternTable = bit.rshift(bit.band(value, 8), 3)
    spriteSize = bit.rshift(bit.band(value, 0x20), 5)
end

function mod.updatePpuMask(value)
    showSprites = bit.band(value, 0x10) ~= 0
    showLeftmost = bit.band(value, 0x04) ~= 0
    grayscale = bit.band(value, 0x01) ~= 0
end

return mod
