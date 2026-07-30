local width, height = term.getSize()
local accent = colors.lightBlue
local muted = colors.lightGray
local logo = {
    "       d8888 88888888888 888             d8888  .d8888b.",
    "      d88888     888     888            d88888 d88P  Y88b",
    "     d88P888     888     888           d88P888 Y88b.     ",
    "    d88P 888     888     888          d88P 888  \"Y888b.  ",
    "   d88P  888     888     888         d88P  888     \"Y88b.",
    "  d88P   888     888     888        d88P   888       \"888",
    " d8888888888     888     888       d8888888888 Y88b  d88P",
    "d88P     888     888     88888888 d88P     888  \"Y8888P\" "
}
local gradient = {
    colors.white, colors.pink, colors.magenta, colors.purple, colors.gray
}

local function centered(y, text, color)
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), y)
    term.setTextColor(color)
    term.write(text:sub(1, width))
end

local function drawLogo(top)
    for row, text in ipairs(logo) do
        local left = math.max(1, math.floor((width - #text) / 2) + 1)
        local run = 0
        for column = 1, #text do
            local character = text:sub(column, column)
            if character == " " then
                run = 0
            elseif left + column - 1 <= width then
                run = run + 1
                local shade = math.min(#gradient,
                    1 + math.floor((row - 1) / 2)
                        + math.floor((run - 1) / 2))
                term.setCursorPos(left + column - 1, top + row - 1)
                term.setTextColor(gradient[shade])
                term.write(character)
            end
        end
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.setCursorBlink(false)
term.clear()

local logoTop = math.max(2, math.floor((height - 17) / 2))
drawLogo(logoTop)
centered(logoTop + 9, "SHARED TERRAIN NETWORK", muted)
centered(logoTop + 11, "DATABASE NODE", colors.white)

for step = 1, 6 do
    local bar = "[" .. string.rep("=", step)
        .. string.rep(" ", 6 - step) .. "]"
    centered(logoTop + 13, bar, accent)
    sleep(0.08)
end

centered(logoTop + 15, "MOUNTING STORAGE VOLUMES", muted)
sleep(0.12)
term.clear()
term.setCursorPos(1, 1)
shell.run("atlas-station")
