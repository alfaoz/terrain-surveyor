return {
    name = "atlas-navigator",
    version = "1.3.1",
    description = "Shared ATLAS CC:Graphics terrain, cache, and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        }
    },

    hashes = {
        ["navigator.lua"] = "17ccec1cee154a3fa1d73de066b9e7d7743bb65c4111bd6263b7ef4b248f5050"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-navigator with a Terrain Surveyor and wireless modem attached."
}
