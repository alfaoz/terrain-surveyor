return {
    name = "atlas-navigator",
    version = "1.1.0",
    description = "ATLAS CC:Graphics aircraft terrain and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        }
    },

    hashes = {
        ["navigator.lua"] = "adfc1462e67b058d629eab3499db0a5e76161dd8f55ca059f312aaa04352c603"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-navigator with a Terrain Surveyor and wireless modem attached."
}
