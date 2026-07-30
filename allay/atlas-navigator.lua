return {
    name = "atlas-navigator",
    version = "1.4.0",
    description = "Shared ATLAS terrain, POI, cache, and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        },
        startup = {
            ["startup-navigator.lua"] = "50_atlas.lua"
        }
    },

    hashes = {
        ["navigator.lua"] = "60f4a0423b4671800efaee16890fa868d1d74a17e8e17bc4ff5b143ac689d76a",
        ["startup-navigator.lua"] = "cccc60edf8a1b7405b7cb3fa21b3dfd281d34a0c18518e98b7bf821756e86a92"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Navigator will start automatically on reboot. Run atlas-navigator to start it now."
}
