return {
    name = "atlas-station",
    version = "1.4.0",
    description = "ATLAS terrain, shared POI, storage rack, and traffic server",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["station.lua"] = "atlas-station"
        },
        startup = {
            ["startup-station.lua"] = "50_atlas.lua"
        }
    },

    hashes = {
        ["station.lua"] = "a1c4dae627735aae9d440130e11091fbc8ad0a91d37b0656f44a4612f948f8b0",
        ["startup-station.lua"] = "23d9aa18fed550cb55de7f6906a49a9abec42be91103f099c73bf20eb572e13b"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Station will start automatically on reboot. Run atlas-station to start it now."
}
