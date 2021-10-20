--[[
    FCEUX Fixer! Fixes some of the shortcomings of FCEUX's half-assed Lua implementation.
    - print does not support \n
    - io.write does absolutely nothing
    - arg is a plain string instead of a table
    - arg is often a nil reference
    - os.exit closes the emulator
]]

local fceuxPrint = print

-- print does not respect newlines!!
function print(...)
    for _, v in ipairs(arg) do
        if type(v) == "string" then
            local start = 1
            for i = 1, #v do
                if (v:sub(i,i)) == "\n" then
                    fceuxPrint(v:sub(start, i - 1))
                    start = i + 1
                end
            end
            fceuxPrint(v:sub(start))
        else
            fceuxPrint(v)
        end
    end
end

-- io.write does nothing!!!
io.write = print

-- Somehow, this doesn't always get called :/
function os.exit(status)
    error(string.format("\n\n%s called os.exit(%d)\n", arg[0], status or 0))
end

-- arg can occasionally go missing, ending up as a nil reference.
assert(arg, "Command line arguments got lost somehow :(\nPlease run this script again.")

-- FCEUX passes arg as a string, but vanilla Lua does a table. Sometimes, this string can be null if you are unlucky.
local argT = {}
for str in arg:gmatch("[^ ]+") do
    table.insert(argT, str) -- table.pack does not exist in FCEUX. I don't know what to say...
end

-- Info at stack level 3 should be the script that required this file.
local info = debug.getinfo(3, "S")
local name = info.source:match("[^/\\]+\.lua")
argT[-1] = "fceux"
argT[0] = name

arg = argT
