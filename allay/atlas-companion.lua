return {
    name = "atlas-companion",
    version = "1.0.0",
    description = "Paired ATLAS pocket moving map and aircraft route controller",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["companion.lua"] = "atlas-companion"
        },
        startup = {
            ["startup-companion.lua"] = "50_atlas.lua"
        }
    },

    hashes = {
        ["companion.lua"] = "ba4d96a51e6660d57e931f587746e38a8376b59ade93cb7f437c5c4eae994e73",
        ["startup-companion.lua"] = "74606d147713d54cae396e0cc84ec4b20e8671cd785e27f61fcb63a77b17d2f4"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Companion will start automatically on reboot. Press PAIR on an aircraft navigator, then run atlas-companion now."
}
