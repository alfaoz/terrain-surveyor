-- Compatibility launcher for the ATLAS Navigator.
local navigator = fs.exists("/atlas/navigator.lua")
    and "/atlas/navigator.lua" or "atlas/navigator.lua"
dofile(navigator)
