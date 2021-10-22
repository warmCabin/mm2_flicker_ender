--[[
    FCEUX Fixer! Fixes some of the shortcomings of FCEUX's half-assed Lua implementation.
    - print does not support \n
    - io.write does absolutely nothing
    - arg is a plain string instead of a table
    - arg is often a nil reference (usually when loading a script with the emulator paused)
    - os.exit closes the emulator
]]

if type(arg) == "table" then
    print("arg is already correct.\nffix is not necessary in your environment!")
    return
end

local fceuxPrint = print

-- FCEUX print does not respect newlines!
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

-- FCEUX io.write does nothing!
io.write = print

-- Somehow, this doesn't always get called :/
function os.exit(status)
    error(string.format("\n\n%s called os.exit(%d)\n", arg[0], status or 0))
end

-- arg can occasionally go missing, ending up as a nil reference.
assert(arg, "Command line arguments got lost somehow :(\nPlease run this script again.")

local function clean(str)
    local ret = ""
    local start = 1
    for j = 1, #str do
        if str:sub(j, j) == '"' then
            if j ~= 1 and str:sub(j - 1, j - 1) == '\\' then
                -- leave quote, remove backslash
                ret = ret..str:sub(start, j - 2)..'"'
                start = j + 1
            else
                -- remove quote
                ret = ret..str:sub(start, j - 1)
                start = j + 1
            end
        end
    end
    
    if start <= #str then
        ret = ret..str:sub(start, #str)
    end
    
    return ret
end

-- FCEUX passes arg as a single string, but it's supposed to be a table.
local argT = {}

local quoted = false
local start = 1
local stop
for i = 1, #arg do
    if arg:sub(i, i) == '"' and (i == 1 or arg:sub(i - 1, i - 1) ~= '\\') then
        quoted = not quoted
    elseif not quoted and arg:sub(i, i) == " " then
        stop = i - 1
        if stop >= start then
            table.insert(argT, clean(arg:sub(start, stop)))
        end
        start = i + 1
    end
end

stop = #arg
if stop >= start then table.insert(argT, clean(arg:sub(start, stop))) end

for i, str in ipairs(argT) do
    print(string.format("[%d] |%s|", i, str))
end

-- Setup some metadata that's supposed to be in the arg table.
-- [-1] (and below) = name and args of interpreter. "fceux" seemes fine for this.
-- [0] = script name. Info at stack level 3 should be the script that required this file.
local info = debug.getinfo(3, "S")
local name = info.source:match("[^/\\]+\.lua")
argT[-1] = "fceux"
argT[0] = name

arg = argT
