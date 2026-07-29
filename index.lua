return {
    spec = "allay/v1.0.0",
    format = "allay",
    name = "alfaoz/terrain-surveyor",
    description = "ATLAS terrain database and aircraft navigator",
    homepage = "https://github.com/alfaoz/terrain-surveyor",

    packages = {
        ["atlas-core"] = {
            version = "1.0.0",
            description = "Shared ATLAS protocol and terrain storage library",
            file = "allay/atlas-core.lua"
        },
        ["atlas-station"] = {
            version = "1.0.0",
            description = "Home terrain database, disk rack, and traffic server",
            file = "allay/atlas-station.lua"
        },
        ["atlas-navigator"] = {
            version = "1.0.0",
            description = "CC:Graphics aircraft terrain and waypoint navigator",
            file = "allay/atlas-navigator.lua"
        }
    }
}
