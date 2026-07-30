return {
    name = "atlas-station",
    version = "1.4.2",
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
        ["station.lua"] = "3b1c14d5258edbc943f407f002c0c1421f7e22f77202c27f70f9e179187db6b4",
        ["startup-station.lua"] = "e13556c4932f197ca6380b55035df2159eaeed9077e4f44737b3493de09d59fb"
    },

    dependencies = { "atlas-core" },
    post_install_message = "ATLAS Station will start automatically on reboot. Run atlas-station to start it now."
}
