return {
    name = "atlas-navigator",
    version = "1.3.0",
    description = "Shared ATLAS CC:Graphics terrain, cache, and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        }
    },

    hashes = {
        ["navigator.lua"] = "788d96d6321dd0bb19b88bdafd7219b8222d3ae9ea676109adbbfcf15ce3a04b"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-navigator with a Terrain Surveyor and wireless modem attached."
}
