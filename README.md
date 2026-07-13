# Meadow

An autonomous low-poly 3D ecosystem. Deer graze in flocking herds, wolves hunt
them one on one, grass gets eaten down and grows back, berry bushes refill,
animals are born and die. Nobody controls it. The balance holds itself up
through energy economics, and the camera flies around on its own finding the
drama: chases, kills, births.

Same architecture as my battle simulation project: authoritative **Elixir**
server, **Swift + Metal** macOS client that only renders interpolated state,
zero external dependencies on either side.

```
Elixir (20 Hz ecology) --binary WebSocket--> Swift/Metal (60 fps, interpolation + FX + camera)
```

## Running it

Scripts in the repo root (make them executable once with `chmod +x *.sh`):

- `./build.sh` builds the server and, on macOS, the client.
- `./run.sh` (macOS) starts the server in the background, waits for the port,
  launches the client and stops the server on exit.
- `./run-server.sh` runs only the server.
- `./run-client.sh` runs only the client (macOS).

Environment variables: `PORT` (default 4041), `HOST`, `CONFIG` (`release` or
`debug`). `TICK_MS` speeds up the server for headless balance testing: the
simulation dt stays fixed at 50 ms, so `TICK_MS=10` runs the ecology at 5x
wall speed.

Manually, in two terminals:

```
cd server
mix run --no-halt
```

```
cd client
swift run -c release
```

Requirements: Elixir 1.14+ for the server, macOS 13+ with the Xcode toolchain
for the client.

## Camera and controls

The default camera is a manual observer hovering over the meadow at a tilt:

- **W A S D** or arrow keys: pan across the field, relative to view heading
- **Q / E** or mouse drag: rotate; drag vertically to tilt
- **scroll wheel**: zoom; pan speed scales with zoom so travel feels constant
- **C**: toggle the cinematic auto camera

The cinematic mode is a heat-driven director: kills and hunt starts deposit
heat, the camera frames the weighted centroid of recent action and cuts
between orbit, flyover, low track and crane shots. Good for leaving the
simulation running as an ambient scene or recording video; for actually
following individual animals the manual camera is the tool.

## The ecology

**Herbivores (deer)** move by classic boids: separation, alignment, cohesion.
Panic propagates through the herd on its own, because a fleeing deer's
velocity drags neighbors along via the alignment term. Grass and berries add
energy, movement drains it, fleeing drains it fast. High energy plus low local
crowding produces a calf. Calves are smaller and slower, which matters below.

**Predators (wolves)** hunt alone. Target selection prefers isolated prey:
candidate distance is weighted up by the number of herd neighbors and down by
body size, so stragglers and calves get picked first. The chase is a sprint
with limited stamina. A sprinting wolf outruns an adult deer slightly; a tired
wolf does not. Herds escape, loners get caught. Wolves reproduce when well fed
and die of starvation or old age.

**Food** is a 36x24 grass grid with logistic regrowth plus a dozen berry
bushes. Grazed cells visibly turn brown on the ground and green back over
time, so you can watch the herds strip a patch and move on.

**Day and night.** The world runs a 3 minute day cycle. After dark, deer
detection range drops (darkness favors the hunter), well-fed deer bed down in
tight huddles, and wolves hunt more eagerly. Nights are when most kills
happen. The client follows along: the sun sweeps the sky, dusk goes orange,
stars come out, the scene shifts to bluish moonlight and fireflies drift over
the grass.

**Seasons.** Grass regrowth is not uniform: a fertile band sweeps across the
field over a 10 minute cycle, and grass outside it withers toward a dry
floor. Herds follow the food, so the whole population migrates across the map
season after season. There is no migration code in the herbivore; it falls
out of the grazing behavior plus a moving resource.

**Self-balancing.** The energy economy produces Lotka-Volterra style dynamics:
prey density up, hunting gets easier, wolves breed, prey density down, wolves
starve. Birth rates are damped by population density on both sides. As a
final guarantee for an eternally running scene, a small group migrates in from
the field edge if either species collapses below a floor.

In headless accelerated runs the system settles into a live equilibrium:
deer breathing between 150 and 190 in step with the seasons, wolves 11-12
with steady generational turnover, grass swinging 0.55-0.8 as the fertile
band moves, and a kill somewhere on the field every few seconds. That pacing
is what feeds the camera.

## Two bugs worth remembering

**Force integration versus velocity targeting.** The first version integrated
steering forces with per-tick velocity damping. The equilibrium speed of that
system is accel * dt / (1 - damping), and for the wolf's chase it came out to
4.7 m/s against a deer fleeing at 7.4. Hunt success rate: 4 percent. The
predators were mathematically incapable of catching anyone, and the whole
population starved no matter how the rewards were tuned. Chases and flights
now use velocity targeting (converge the velocity vector onto direction times
speed cap), which guarantees animals actually reach their top speed. Success
rate jumped to a realistic wolves-pick-winnable-hunts level, and the ecology
came alive.

**Silent patch failures.** Two of the balance patches applied earlier in
development never actually landed, because a scripted string replacement
matched nothing and reported success anyway. The lesson: after any automated
edit, grep for the new value before trusting the test results.

## Architecture notes

The server is one GenServer with a fixed 50 ms tick and a flat agent map, no
process per animal. Neighbor queries for flocking go through a coarse spatial
hash (8 m buckets), so each boids update touches at most nine buckets instead
of scanning every animal. The WebSocket server is hand-rolled over
`:gen_tcp` (RFC 6455), and each connection is a process that receives frames
from the sim by plain message passing. Behavior lives in separate modules:
`Herbivore`, `Predator`, `Food`, `Grid`, with `Sim` only orchestrating the
tick.

The binary protocol, little-endian:

```
header:  tick u32 | n_agents u16 | n_events u16 | grass_w u8 | grass_h u8
grass:   grass_w * grass_h bytes, cell amount 0..255
agent:   id u16 | flags u8 | scale u8 | x i16 | z i16 | heading i16   (10 bytes)
event:   type u8 | aux u8 | x i16 | z i16 | extra u16                 (8 bytes)
```

`flags`: bits 0-1 species (herbivore, predator, bush), bits 2-4 state (head
down, walk, run, dead, idle, eat). `scale` carries model scale for animals
(calves grow into adults) and berry fill for bushes. Positions are fixed-point
1/64 m. Event types: kill, birth, starvation, berry eaten, hunt started.

The client keeps the last two snapshots per agent and interpolates, rendering
about one network interval behind the server. The roster is dynamic (animals
are born and die), so tracks are created and pruned as ids appear and vanish.
The grass grid is uploaded every frame into a 36x24 r8 texture the ground
shader samples for its lush-to-grazed tint. All animal animation (diagonal
gait, grazing head, death topple, tail wag) runs in the vertex shader from a
per-instance phase and state. The camera director weights kills and hunt
starts highest, so it gravitates toward chases; when the meadow is quiet it
frames the herd centroid and just watches.

## Tuning

Ecology constants live in `server/lib/meadow/herbivore.ex`,
`server/lib/meadow/predator.ex` and `server/lib/meadow/sim.ex` as module
attributes: speeds, ranges, energy gains and drains, reproduction thresholds,
population caps and floors. The stats counter inside the sim state
(`:sys.get_state(Meadow.Sim).stats`) tracks cumulative hunts, kills, births
and deaths, which makes headless balance runs measurable instead of vibes.

## Ideas for later

- A web viewer speaking the same protocol.
- Weather: rain bursts that accelerate regrowth where they pass.
