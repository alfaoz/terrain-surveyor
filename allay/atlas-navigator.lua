return {
    name = "atlas-navigator",
    version = "1.5.1",
    description = "Shared ATLAS terrain, companion, POI, cache, and waypoint navigator",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["navigator.lua"] = "atlas-navigator"
        },
        raw = {
            ["companion-host.lua"] = "/atlas/companion-host.lua"
        },
        startup = {
            ["startup-navigator.lua"] = "50_atlas.lua"
        }
    },

    hashes = {
        ["navigator.lua"] = "6c9934a5070ca6886f1eb0ff5e5aa6d5d8720befbf4de92c9117b2de38d86c81",
        ["companion-host.lua"] = "3e0aa5dee5c9c98d6bb5c4998768261290a819a024e7149022d58b078c39d9e0",
        ["startup-navigator.lua"] = "0f2e47de97f4a9e2f68cbfc3154249932641adc2630fc0dbbaf98b95c3876295"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Navigator will start automatically on reboot. Run atlas-navigator to start it now."
}
