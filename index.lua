return {
    spec = "allay/v1.0.0",
    format = "allay",
    name = "alfaoz/terrain-surveyor",
    description = "ATLAS terrain database and aircraft navigator",
    homepage = "https://github.com/alfaoz/terrain-surveyor",

    packages = {
        ["atlas-core"] = {
            version = "1.3.0",
            description = "Shared ATLAS protocol and terrain storage library",
            file = "allay/atlas-core.lua"
        },
        ["atlas-station"] = {
            version = "1.4.2",
            description = "Shared terrain and POI database, disk rack, and traffic server",
            file = "allay/atlas-station.lua"
        },
        ["atlas-navigator"] = {
            version = "1.5.1",
            description = "Shared CC:Graphics terrain, companion, POI, and waypoint navigator",
            file = "allay/atlas-navigator.lua"
        },
        ["atlas-companion"] = {
            version = "1.0.2",
            description = "Paired pocket moving map and live aircraft route controller",
            file = "allay/atlas-companion.lua"
        }
    }
}
