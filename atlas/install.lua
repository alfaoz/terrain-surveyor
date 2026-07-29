local URLS = {
    library = "https://gist.githubusercontent.com/alfaoz/611e69042b3bdb787bfbfba2793ae603/raw/7a5675adcff52de7bc4b974195c571ee2a3d60d6/lib.lua",
    station = "https://gist.githubusercontent.com/alfaoz/611e69042b3bdb787bfbfba2793ae603/raw/68ff2e67a21d63e2bb1ed778213bea50fb73c45f/station.lua",
    navigator = "https://gist.githubusercontent.com/alfaoz/611e69042b3bdb787bfbfba2793ae603/raw/9ddb09c67b8720b9d017ffa3bbbeaaffb6615a5c/navigator.lua"
}

local arguments = { ... }
local role = arguments[1] and arguments[1]:lower()
local startup = arguments[2] and arguments[2]:lower() == "startup"

if role ~= "station" and role ~= "navigator" and role ~= "both" then
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS INSTALLER")
    print()
    print("1. ATLAS Station")
    print("2. ATLAS Navigator")
    print("3. Both applications")
    print()
    write("Install: ")
    local answer = read()
    role = answer == "1" and "station"
        or answer == "2" and "navigator"
        or answer == "3" and "both"
        or nil
end

if not role then error("Installation cancelled", 0) end

local function installFile(url, destination)
    local temporary = destination .. ".download"
    local backup = destination .. ".previous"
    if fs.exists(temporary) then fs.delete(temporary) end
    fs.makeDir(fs.getDir(destination))

    print("Downloading " .. fs.getName(destination) .. "...")
    if not shell.run("wget", url, temporary) or not fs.exists(temporary) then
        error("Could not download " .. destination, 0)
    end

    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(destination) then fs.move(destination, backup) end
    local ok, failure = pcall(fs.move, temporary, destination)
    if not ok then
        if fs.exists(backup) and not fs.exists(destination) then
            fs.move(backup, destination)
        end
        error("Could not install " .. destination .. ": " .. tostring(failure), 0)
    end
    if fs.exists(backup) then fs.delete(backup) end
end

installFile(URLS.library, "/atlas/lib.lua")
if role == "station" or role == "both" then
    installFile(URLS.station, "/atlas/station.lua")
end
if role == "navigator" or role == "both" then
    installFile(URLS.navigator, "/atlas/navigator.lua")
end

if startup and role ~= "both" then
    local atlas = dofile("/atlas/lib.lua")
    local target = role == "station"
        and "/atlas/station.lua" or "/atlas/navigator.lua"
    local ok, failure = atlas.writeAtomic(
        "/startup/atlas.lua",
        ('shell.run("%s")\n'):format(target),
        false)
    if not ok then error("Could not install startup file: " .. tostring(failure), 0) end
end

print()
print("ATLAS installation complete.")
if role == "station" then
    print("Run: /atlas/station.lua")
elseif role == "navigator" then
    print("Run: /atlas/navigator.lua")
else
    print("Run /atlas/station.lua or /atlas/navigator.lua")
end
if startup and role ~= "both" then print("Automatic startup enabled.") end
