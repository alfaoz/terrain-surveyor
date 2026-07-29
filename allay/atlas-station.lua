return {
    name = "atlas-station",
    version = "1.1.0",
    description = "ATLAS home terrain database, storage rack, and traffic server",
    author = "alfaoz",

    base_url = "https://raw.githubusercontent.com/alfaoz/terrain-surveyor/main/atlas",

    files = {
        bin = {
            ["station.lua"] = "atlas-station"
        }
    },

    hashes = {
        ["station.lua"] = "0520b132d5f404f67c4647f8df6912deb4261bb6e5b6418f2b6ea6d0af0c6f00"
    },

    dependencies = { "atlas-core" },
    post_install_message = "Run atlas-station. Press M for maintenance, then initialize empty data disks with I."
}
