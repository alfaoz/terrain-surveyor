return {
    name = "atlas-station",
    version = "1.2.0",
    description = "ATLAS shared terrain database, storage rack, and traffic server",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["station.lua"] = "atlas-station"
        }
    },

    hashes = {
        ["station.lua"] = "6c6218c51937952e0050c5c86ebe49941db4ea1982a5400353a138663156ab79"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-station. Press M for maintenance, then initialize empty data disks with I."
}
