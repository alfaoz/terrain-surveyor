return {
    name = "atlas-station",
    version = "1.3.0",
    description = "ATLAS streaming terrain database, storage rack, and traffic server",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["station.lua"] = "atlas-station"
        }
    },

    hashes = {
        ["station.lua"] = "4ab8142947f31968f9c8f13c5d0257c48d4dfeaa928882ef74e7712f9df19725"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-station. Press M for maintenance, then initialize empty data disks with I."
}
