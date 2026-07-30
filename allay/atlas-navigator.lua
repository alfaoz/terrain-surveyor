return {
    name = "atlas-navigator",
    version = "1.4.2",
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
        ["navigator.lua"] = "be1db8c55911339c054acbc34349aad2a93975e39df9c16f16b20c3d73d29f4c",
        ["startup-navigator.lua"] = "0f2e47de97f4a9e2f68cbfc3154249932641adc2630fc0dbbaf98b95c3876295"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Navigator will start automatically on reboot. Run atlas-navigator to start it now."
}
