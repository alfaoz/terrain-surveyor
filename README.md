# Terrain Surveyor

A small, passive CC:Tweaked peripheral for obtaining full-resolution terrain
height data from a piloted Sable contraption. It is built for NeoForge 1.21.1
and does not use Advanced Peripherals.

The current block deliberately uses the vanilla Acacia Button model and texture
as a placeholder. It can be mounted on a floor, wall, or ceiling, has no GUI,
does not emit redstone, and needs no kinetic power.

## Target versions

- Minecraft 1.21.1
- NeoForge 21.1.243
- CC:Tweaked 1.120.0
- Create 6.0.10
- Sable 2.0.3 (including Sable Companion 1.6.0)
- Create: CC Better Recipes 1.2.0

## Survival crafting

The Terrain Imaging Core begins with a Create Precision Mechanism.

The sequenced assembly repeats these five operations three times:

1. Deploy a Copper Sheet.
2. Deploy an Amethyst Shard.
3. Deploy Redstone Dust.
4. Press the assembly.
5. Deploy Polished Rose Quartz.

This outputs a Layered Terrain Imaging Assembly. A separate, one-off Deployer
then applies one `ccbr:integrated_circuit` to finish the Terrain Imaging Core.

The final shaped recipe is:

```text
Brass Sheet | Electron Tube        | Brass Sheet
Brass Sheet | Terrain Imaging Core | Brass Sheet
Brass Sheet | Compass              | Brass Sheet
```

## Peripheral API

Attach the surveyor directly to a CC:Tweaked computer and locate it with:

```lua
local surveyor = peripheral.find("terrain_surveyor")
assert(surveyor, "No Terrain Surveyor attached")
```

### `getInfo()`

Returns the Sable-projected world position, current chunk, and supported
radius.

### `scanChunk(dx, dz)`

Scans an already-loaded chunk relative to the chunk containing the surveyor.
Both offsets must be between `-8` and `8`, providing a 17×17-chunk survey
window centered on the aircraft. Calling the method does not generate, load, or
force-load chunks, so results are still bounded by the server's loaded-chunk
distance. There is no peripheral cooldown; the calling CraftOS program controls
the scan rate.

### `scanBatch(requests, maxChunks, budgetMicros)`

Scans several already-loaded chunks in one server-thread call. `requests` is
an array of `{ dx, dz }` offsets or `{ chunkX, chunkZ }` absolute chunk
coordinates. One call accepts up to 96 candidates, completes at most 16
chunks, and clamps its server-thread budget to 0.5–8 milliseconds. Unloaded
and budget-deferred requests are returned separately:

```lua
local result = surveyor.scanBatch({
  { dx = 0, dz = 0 },
  { dx = 0, dz = -1 },
  { dx = 1, dz = -1 }
}, 16, 8000)

print("scanned", #result.tiles)
print("not loaded", #result.unloaded)
print("deferred", #result.deferred)
```

ATLAS automatically expands to the full 16-chunk/8 ms batch while the
aircraft is moving quickly. At lower speeds it uses the configured, gentler
budget.

The scan runs on the Minecraft server thread and returns:

```lua
{
  version = 1,
  dimension = "minecraft:overworld",
  chunkX = 0,
  chunkZ = 0,
  minY = -64,
  maxY = 319,
  width = 16,
  depth = 16,
  order = "z_major",
  byteOrder = "big_endian",

  surface = "<512-byte binary string>",
  clearance = "<512-byte binary string>",
  fluid = "<512-byte binary string>",
  flags = "<256-byte binary string>",
  checksum = "8 hexadecimal CRC-32 digits"
}
```

There is one sample for every X/Z block in the chunk. Samples use
`index = z * 16 + x`, with local X and Z in the range 0–15.

- `surface`: solid surface height after ignoring leaves, glass, fluids, and
  replaceable vegetation.
- `clearance`: highest collidable obstacle, including leaves and glass.
- `fluid`: highest exposed fluid found above the solid surface.
- `flags`: two fluid-kind bits plus a bit indicating an obstacle above the
  surface.

Each height is an unsigned, big-endian 16-bit offset from `minY`. `65535`
means no height was found. Flag bits are:

- bits 0–1: `0` none, `1` water, `2` lava, `3` other fluid
- bit 2: clearance is higher than surface

Example decoder:

```lua
local function decodeHeight(tile, field, x, z)
  local data = tile[field]
  local sample = z * 16 + x
  local byteIndex = sample * 2 + 1
  local encoded = data:byte(byteIndex) * 256 + data:byte(byteIndex + 1)
  if encoded == 0xffff then return nil end
  return tile.minY + encoded
end

local tile = surveyor.scanChunk(0, 0)
print("surface:", decodeHeight(tile, "surface", 8, 8))
print("clearance:", decodeHeight(tile, "clearance", 8, 8))
```

## Block classification

The defaults are datapack tags and can be extended by a modpack:

- `terrain_surveyor:surface_ignored`
- `terrain_surveyor:clearance_ignored`

This keeps the terrain rules editable without rebuilding the mod. The supplied
surface tag ignores vanilla leaves, glass blocks and panes, flowers, fluids,
and replaceable vegetation. Clearance ignores harmless replaceable vegetation
but still includes collidable transparent obstacles.

## ATLAS

The `atlas/` directory contains the first complete ATLAS application:

- `lib.lua`: shared protocol, terrain-file, capacity, and peripheral helpers.
- `station.lua`: the home map station, storage-rack controller, traffic
  service, and persistent shared POI database. Its interface runs entirely on
  the station computer.
- `navigator.lua`: the onboard CC: Graphics navigator, persistent cache,
  local route waypoints, shared POIs, smart survey scheduler, network prefetch,
  and live traffic.

ATLAS volumes are ordinary floppy disks attached through any number of wired
disk drives. The station detects their real capacity with `fs.getCapacity` and
`fs.getFreeSpace`; no computer or floppy capacity is hardcoded.

### Install ATLAS with Allay

Install Allay once:

```lua
wget run https://raw.githubusercontent.com/allaycc/allay/main/install.lua
```

Add this repository as a package source:

```text
allay source add alfaoz/terrain-surveyor
```

On the home station computer:

```text
allay install atlas-station
```

Fresh empty floppies appear as `UNFORMATTED`. Open Storage, enter maintenance,
and use `INIT` for the selected disk or `INIT ALL` (`A`) for every empty disk
in the rack. `INIT ALL` never touches disks marked `FOREIGN`.

On each aircraft computer:

```text
allay install atlas-navigator
```

Both Allay packages install their own managed startup launcher. Reboot the
computer to start the selected ATLAS role automatically, or run
`atlas-station`/`atlas-navigator` once to start it immediately. Keep the actual
programs in `/bin` and `/atlas`; Allay updates those files in place. The
launchers show a short centered ATLAS boot sequence and adapt to the available
terminal size, including a 74 by 31 computer terminal.

An empty data disk in any attached onboard disk drive is automatically
initialized as an `ATLAS AIR CACHE`. The computer filesystem and every attached
air-cache disk form one storage pool; capacity is detected at runtime. Station
tiles are mirrored in the background even when they are outside the visible
map. Flight-corridor and nearby tiles always outrank the background mirror.
When storage pressure requires replacement, synchronized distant tiles are
evicted first. Newly surveyed data is pinned until the station confirms that
it has stored the same checksum.

`atlas-station` and `atlas-navigator` both depend on `atlas-core`, which Allay
installs and updates automatically. The package manifests pin SHA-256 hashes
for every downloaded Lua file.

## Legacy launcher

[`examples/terrain_map.lua`](examples/terrain_map.lua) launches the ATLAS
Navigator for compatibility with the earlier terrain-map prototype.

Controls:

- `+` / `-` or mouse wheel: zoom in and out
- Click, scroll, or drag over the map: show surface, clearance, and fluid
  details for that map point
- Arrow keys: pan and leave follow mode
- Space, Escape, `B`, or the `CTR` button: recenter and resume follow mode
- `HOME`: return to the network menu without closing the navigator
- On startup, the navigator automatically reconnects to the remembered station;
  if it is unavailable, the network menu opens instead
- `C` on the Home screen: change the vehicle code (`XX-NN`, such as `AC-01`)
- `G`: toggle chunk grid
- `C`: toggle 10-block contour lines
- `O`: toggle clearance-obstacle stippling
- `W`: enter an exact waypoint
- Left-click the map: append a waypoint immediately
- Right-click a waypoint marker: delete that waypoint
- `X` or the `DEL` button: delete the active waypoint
- `N`: advance to the next waypoint
- Middle-click the map: create a shared POI at that location
- Click a POI marker: select it and show its saved details
- Right-click a POI marker: open its in-map `EDIT` / `DELETE` menu
- `P` or `POI`: create a POI, or edit the selected POI
- `GO`: append the selected POI to the aircraft's active route
- `E`: edit the selected POI
- `K` or `PDEL`: delete the selected POI after confirmation
- `H`: calibrate CC:Sable heading to the current straight-line ground track
- `R`: rescan the current chunk
- `Q`: close and return to text mode

The zoom levels range from four blocks per pixel to eight pixels per block.
Unknown tiles remain dark until the aircraft obtains them. The station is the
shared source of truth: the navigator first loads its onboard cache, bulk-checks
visible tile checksums against the station, downloads shared tiles contributed
by other aircraft, and only surveys after the station explicitly reports that a
tile is missing. Known tiles are never automatically rescanned; `R` is the
explicit resurvey command.

Shared POIs have a name, category, dimension, X/Z position, and optional
altitude. The selected station is the source of truth and stores them
atomically in `/atlas/pois.dat`. Every connected navigator checks the list
about once per second and saves an onboard copy, so POIs remain visible if the
link drops. Creating, editing, and deleting POIs uses the station write key
when one is configured. Route waypoints remain private to an aircraft and are
not mixed into the shared POI database.

The POI editor and deletion confirmation are graphical overlays, so the
navigator never leaves the live map while managing a POI. On the station,
open page `4 POIS` to browse the server-owned list. Select a POI and press
`DELETE` (or `D`); the station requires `CONFIRM DELETE` before permanently
removing it for every aircraft.

The navigator polls position and redraws at the Minecraft tick rate. At speed,
the native surveyor scans up to 16 station-confirmed missing chunks per poll
inside an 8 ms server-thread budget and prioritizes a narrow forward corridor.
Disk writes run in a separate buffered worker. The footer reports measured
chunks per second, scan backlog, and mapped seconds ahead.

ATLAS Link requests windows of up to 98 terrain tiles. The station streams
those as reliable 14-tile segments with three segments in flight, per-segment
acknowledgements, and automatic retry. Survey uploads use 14-tile batches too.
The station exposes a paged map catalog, allowing every connected aircraft to
mirror the shared map independently of its current viewport. The navigator
keeps at least a 24-chunk local cache circle, extends a speed-dependent forward
cone as far as 64 chunks, and prioritizes all entered waypoint corridors.

The station storage screen provides clickable maintenance controls and
expanded details for the selected disk. If only a wired modem is present, the
station remains usable in `WIRED` mode and automatically enables wireless
service when an Ender Modem is attached.

Unsynced terrain remains in the aircraft cache. Deferred, rejected, or timed
out uploads retry automatically with exponential backoff, capped at 30 seconds,
so maintenance or temporarily missing station storage cannot lose survey data.
If a station is missing a tile that remains in an aircraft cache, the navigator
uploads that cached copy and repairs the shared map.

### ATLAS bandwidth benchmark

[`examples/atlas_bandwidth_test.lua`](examples/atlas_bandwidth_test.lua) runs
on two modem-equipped computers and measures reliable payload size, latency,
and throughput in both directions:

```text
wget run https://gist.githubusercontent.com/alfaoz/1ebe93f01feeb891cc3cd74cff027b4b/raw/a8bd3f2028e3126adb8a2b3a358b13ad56e6a79b/atlas_bandwidth_test.lua server
wget run https://gist.githubusercontent.com/alfaoz/1ebe93f01feeb891cc3cd74cff027b4b/raw/a8bd3f2028e3126adb8a2b3a358b13ad56e6a79b/atlas_bandwidth_test.lua client
```

The client writes the detailed result table to `/atlas-bench.txt`. Use its
suggested safe payload size to tune the tile batch size for a particular
server/modpack/network.

## Build

```sh
./gradlew clean build
```

The distributable JAR is written to `build/libs/`.

For a local integration run against the exact target profile:

```sh
./gradlew runServer \
  -Plocal_mods_dir="/absolute/path/to/the/profile/mods"
```

That optional test runtime loads only CC:Tweaked, Create, Sable, and CC Better
Recipes from the profile.
