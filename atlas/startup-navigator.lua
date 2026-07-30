local width, height = term.getSize()
local accent = colors.orange
local muted = colors.lightGray
local logo = {
    "    /\\    ______  __        /\\      ______",
    "   /  \\     ||   ||       /  \\    /_____ ",
    "  /----\\    ||   ||      /----\\         \\",
    " /      \\   ||   ||___  /      \\  ______/"
}

local function centered(y, text, color)
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), y)
    term.setTextColor(color)
    term.write(text:sub(1, width))
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.setCursorBlink(false)
term.clear()

local logoTop = math.max(3, math.floor((height - 14) / 2))
for index, text in ipairs(logo) do
    centered(logoTop + index - 1, text,
        index % 2 == 0 and colors.yellow or accent)
end
centered(logoTop + 6, "SHARED TERRAIN NETWORK", muted)
centered(logoTop + 8, "NAVIGATION NODE", colors.white)

for step = 1, 6 do
    local bar = "[" .. string.rep("=", step)
        .. string.rep(" ", 6 - step) .. "]"
    centered(logoTop + 10, bar, accent)
    sleep(0.08)
end

centered(logoTop + 12, "INITIALIZING FLIGHT DISPLAY", muted)
sleep(0.12)
term.clear()
term.setCursorPos(1, 1)
shell.run("atlas-navigator")
