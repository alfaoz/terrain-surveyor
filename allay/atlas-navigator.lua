return {
    name = "atlas-navigator",
    version = "1.5.0",
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
        ["navigator.lua"] = "8bbaf2b54adeb7b758304c41f8023800f3b0ed785adeaccaf1e056e22ba01513",
        ["companion-host.lua"] = "3e0aa5dee5c9c98d6bb5c4998768261290a819a024e7149022d58b078c39d9e0",
        ["startup-navigator.lua"] = "0f2e47de97f4a9e2f68cbfc3154249932641adc2630fc0dbbaf98b95c3876295"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Navigator will start automatically on reboot. Run atlas-navigator to start it now."
}
