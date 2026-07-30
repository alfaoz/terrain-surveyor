return {
    name = "atlas-navigator",
    version = "1.5.2",
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
        ["navigator.lua"] = "bad676c9980749bb499186b7ade6e7a0e46d4f810f900089ddffba47a3e27029",
        ["companion-host.lua"] = "4e07a2f671ec957f33a8e9d266ea35a9239e72ff44507857d9d5c1f158ba77f9",
        ["startup-navigator.lua"] = "0f2e47de97f4a9e2f68cbfc3154249932641adc2630fc0dbbaf98b95c3876295"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Navigator will start automatically on reboot. Run atlas-navigator to start it now."
}
