return {
    name = "atlas-navigator",
    version = "1.2.0",
    description = "Shared ATLAS CC:Graphics terrain and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        }
    },

    hashes = {
        ["navigator.lua"] = "ae7b9cef33e608700faf1c9dda3f3ac1b20477bf8f83d201b40fa725554f62dc"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-navigator with a Terrain Surveyor and wireless modem attached."
}
