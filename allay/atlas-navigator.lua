return {
    name = "atlas-navigator",
    version = "1.0.0",
    description = "ATLAS CC:Graphics aircraft terrain and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        }
    },

    hashes = {
        ["navigator.lua"] = "8922e946a3eee39c1d8a445acc6ea1a2218dd0de69b1e0fb640462f20934ceb1"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-navigator with a Terrain Surveyor and wireless modem attached."
}
