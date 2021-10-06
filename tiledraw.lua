local bit = require("bit")

local mod = {}

local patternTable = 0
local spriteSize = 0 -- 0 == 8x8

local showLeftmost = true
local showSprites = true
local grayscale = false

-- Create lookup table for octal to binary
local oct2bin = {
    ['0'] = '000',
    ['1'] = '001',
    ['2'] = '010',
    ['3'] = '011',
    ['4'] = '100',
    ['5'] = '101',
    ['6'] = '110',
    ['7'] = '111'
}
local function getOct2bin(a)
    return oct2bin[a]
end

local function convertBin(n)
    local s = string.format('%o', n)
    -- print("octal: "..s)
    s = s:gsub('.', getOct2bin)
    -- print("subbed: "..s)
    
    s = string.rep('0', 9 - #s)..s
    -- print("+ rep: "..s)
    s = s:sub(2)
    -- print("final: "..s)
    
    return s
end

local function mergePlanes(plane0, plane1)
    local str = ""
    for i = 7, 0, -1 do
        local mask = bit.lshift(1, i)
        local sum = bit.rshift(bit.band(plane0, mask), i) + bit.rshift(bit.band(plane1, mask), i - 1)
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
        --gui.text(10, 20 + 20 * i, convertBin(plane0, 8))
        --gui.text(10, 30 + 20 * i, convertBin(plane1, 8))
        -- gui.text(80, 20 + 10 * i, mergePlanes(plane0, plane1))
        ret[i] = mergePlanes(plane0, plane1)
    end
    
    return ret
end

local function getColor(paletteIndex)
    -- print(string.format("getColor: %02X", paletteIndex))
    local color = ppu.readbyte(0x3F00 + paletteIndex)
    --if paletteIndex ~= 0x11 then
     --   gui.text(80, 100, string.format("getColor: %02X -> %02X", paletteIndex, color))
    --end
    return string.format("P%02X", color)
end

local function shouldDraw(x, y, c, attributes)
    
    -- Color 0 is transparent
    if c == "0" then return false end
    
    if not showLeftmost and x < 8 then return false end
    
    -- If priority bit is off, then it's in front of background
    if bit.band(attributes, 0x20) == 0 then return true end
    
    -- This check isn't perfect. Non-BG colors can have the same color as the BG and obscure sprites.
    -- Instead of shouldDraw == false, maybe could update the color to emu.getscreenpixel()? Have this return that?
    local _, _, _, pal = emu.getscreenpixel(x, y, true)
    return pal == ppu.readbyte(0x3F00)
    
end

local function drawRow(x, y, row, attributes)
    local palette = bit.band(attributes, 3)
    for i = 1, #row do
        local c = row:sub(i, i)
        if shouldDraw(x + i - 1, y, c, attributes) then
            local paletteIndex = 0x10 + palette * 4 + tonumber(c)
            gui.pixel(x + i - 1, y, getColor(paletteIndex))
        end
    end
end

-- Currently only supports 8x8 mode.
-- Priority bit is based on color rather than opacity of pixel.
-- The back-priority sprite obscurring quirk is not implemented.
function mod.drawTile(y, attributes, index, x)

    if not showSprites then
        return
    end
    
    if grayscale then
        gui.text(100, 30, "grayscale mode is not currently supported :(")
        return
    end

    if spriteSize == 1 then
        gui.text(100, 30, "8x16 mode is not currently supported :(")
        return
    end

    local tileData = mod.getTileData(patternTable, index)
    for i = 0, 7 do
        local row = tileData[i]
        if not debugMode then
            drawRow(x, y + 1 + i, row, attributes)
        else 
            drawRow((x + 20 + 0) % 256, (y + 21 + i + 0) % 240, row, attributes)
        end
    end

end

local oam = {}

function mod.bufferDraw(y, attributes, index, x)
    table.insert(oam, {
        y = y,
        attributes = attributes,
        index = index,
        x = x
    })
end

function mod.clearBuffer()
    for k in ipairs(oam) do
        oam[k] = nil
    end
end

-- TODO: lower index == higher priority on NES, so I might want to draw this in reverse order.
function mod.renderBuffer()
    for i, entry in ipairs(oam) do
        mod.drawTile(entry.y, entry.attributes, entry.index, entry.x)
    end
end

function mod.updatePpuCtrl(value)
    patternTable = bit.rshift(bit.band(value, 8), 3)
    spriteSize = bit.rshift(bit.band(value, 0x20), 5)
end

function mod.updatePpuMask(value)
    showSprites = bit.band(value, 0x10) ~= 0
    showLeftmost = bit.band(value, 0x04) ~= 0
end

return mod
