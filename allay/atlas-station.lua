return {
    name = "atlas-station",
    version = "1.0.0",
    description = "ATLAS home terrain database, storage rack, and traffic server",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["station.lua"] = "atlas-station"
        }
    },

    hashes = {
        ["station.lua"] = "1a1a66257ffd354f8068639712ac8895d7f4fd5d3f0e9aa7dd99701ab23bfa77"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-station. Press M for maintenance, then initialize empty data disks with I."
}
