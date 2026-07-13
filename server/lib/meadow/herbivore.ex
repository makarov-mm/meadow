defmodule Meadow.Herbivore do
  @moduledoc """
  Herbivore (deer) behavior. Movement is classic boids (separation, alignment,
  cohesion) blended with grazing and a strong flee response. Panic spreads
  through the herd naturally: a fleeing deer's velocity drags neighbors along
  via the alignment term.

  Energy economy: grass and berries add energy, movement drains it, fleeing
  drains it fast. High energy plus low local crowding leads to a calf. Zero
  energy is starvation.
  """
  alias Meadow.{Const, Food}

  @detect_pred 24.0
  @sep_r 2.6
  @ali_r 9.0
  @coh_r 14.0

  @graze_speed 0.6
  @walk_speed 2.4
  @flee_speed 7.4

  @adult_age 25.0

  def new(id, x, z, age \\ nil) do
    %{
      id: id,
      species: 0,
      state: 1,
      x: x,
      z: z,
      vx: (:rand.uniform() - 0.5) * 2,
      vz: (:rand.uniform() - 0.5) * 2,
      heading: :rand.uniform() * 6.28,
      energy: 150.0 + :rand.uniform() * 60,
      age: age || @adult_age * :rand.uniform(),
      corpse_t: 0.0
    }
  end

  def scale(a), do: min(1.0, 0.55 + a.age / @adult_age * 0.45)

  def step(a, ctx) do
    %{dt: dt, grid: grid, agents: agents} = ctx

    neighbors = Meadow.Grid.nearby(grid, a.x, a.z)

    {flee_x, flee_z, panic} = flee_vector(a, neighbors, ctx.night)

    {ax, az, state, a, ctx} =
      if panic > 0.01 do
        {0.0, 0.0, 2, a, ctx}
      else
        calm_behavior(a, neighbors, ctx)
      end

    # boids terms always contribute a little, fully when calm
    {sx, sz} = separation(a, neighbors)
    {alx, alz} = alignment(a, neighbors)
    {cx, cz} = cohesion(a, neighbors)

    w = if panic > 0.01, do: 0.5, else: 1.0
    ax = ax + sx * 6.0 + (alx * 1.2 + cx * 0.6) * w
    az = az + sz * 6.0 + (alz * 1.2 + cz * 0.6) * w

    {bx, bz} = bounds_force(a)
    ax = ax + bx
    az = az + bz

    size = scale(a)

    cap =
      case state do
        0 -> @graze_speed
        2 -> @flee_speed * (0.45 + 0.55 * size)
        _ -> @walk_speed
      end

    {vx, vz} =
      if state == 2 do
        # velocity targeting for flight: reach full flee speed quickly
        fd = :math.sqrt(flee_x * flee_x + flee_z * flee_z) + 0.001
        k = 0.28
        {a.vx * (1 - k) + flee_x / fd * cap * k + ax * dt,
         a.vz * (1 - k) + flee_z / fd * cap * k + az * dt}
      else
        {a.vx * 0.92 + ax * dt, a.vz * 0.92 + az * dt}
      end

    sp = :math.sqrt(vx * vx + vz * vz)
    {vx, vz} = if sp > cap, do: {vx / sp * cap, vz / sp * cap}, else: {vx, vz}

    x = clamp(a.x + vx * dt, -Const.field_x(), Const.field_x())
    z = clamp(a.z + vz * dt, -Const.field_z(), Const.field_z())

    heading = if sp > 0.2, do: :math.atan2(vz, vx), else: a.heading

    drain =
      case state do
        0 -> 0.5
        2 -> 3.8
        _ -> 1.1
      end

    energy = a.energy - drain * dt
    age = a.age + dt

    a = %{a | x: x, z: z, vx: vx, vz: vz, heading: heading, state: state, energy: energy, age: age}

    cond do
      energy <= 0 ->
        ctx = emit(ctx, {:starve, 0, a.x, a.z})
        {%{a | state: 3, corpse_t: 0.0}, ctx}

      true ->
        maybe_reproduce(a, agents, ctx)
    end
  end

  # ------------------------------------------------------------- behaviors

  defp calm_behavior(a, _neighbors, ctx) do
    hungry = a.energy < 185.0

    cond do
      ctx.night and not hungry ->
        # bed down for the night; cohesion below keeps the herd huddled
        {0.0, 0.0, 4, a, ctx}

      hungry and berry_nearby(a, ctx) != nil ->
        seek_berry(a, ctx)

      hungry and Food.amount_at(ctx.grass, a.x, a.z) > 0.18 ->
        graze(a, ctx)

      hungry ->
        seek_grass(a, ctx)

      true ->
        wander(a, ctx)
    end
  end

  defp graze(a, ctx) do
    {grass, eaten} = Food.graze(ctx.grass, a.x, a.z, 0.9 * ctx.dt)
    a = %{a | energy: min(a.energy + eaten * 105.0, 255.0)}
    {0.0, 0.0, 0, a, %{ctx | grass: grass}}
  end

  defp seek_grass(a, ctx) do
    # sample six fixed directions, walk toward the greenest patch
    best =
      Enum.max_by(0..5, fn i ->
        ang = i * 1.047
        Food.amount_at(ctx.grass, a.x + :math.cos(ang) * 14, a.z + :math.sin(ang) * 14)
      end)

    ang = best * 1.047
    {:math.cos(ang) * 3.0, :math.sin(ang) * 3.0, 1, a, ctx}
  end

  defp berry_nearby(a, ctx) do
    Enum.find(ctx.bushes, fn b ->
      b.berries > 0 and dist2(a.x, a.z, b.x, b.z) < 400.0
    end)
  end

  defp seek_berry(a, ctx) do
    b = berry_nearby(a, ctx)

    if dist2(a.x, a.z, b.x, b.z) < 2.6 do
      ctx = eat_berry(ctx, b)
      a = %{a | energy: min(a.energy + 45.0, 255.0)}
      {0.0, 0.0, 0, a, ctx}
    else
      dx = b.x - a.x
      dz = b.z - a.z
      d = :math.sqrt(dx * dx + dz * dz) + 0.001
      {dx / d * 4.0, dz / d * 4.0, 1, a, ctx}
    end
  end

  defp eat_berry(ctx, bush) do
    bushes =
      Enum.map(ctx.bushes, fn b ->
        if b.id == bush.id, do: %{b | berries: b.berries - 1}, else: b
      end)

    emit(%{ctx | bushes: bushes}, {:berry, 0, bush.x, bush.z})
  end

  defp wander(a, ctx) do
    ang = a.heading + (:rand.uniform() - 0.5) * 1.2
    {:math.cos(ang) * 1.2, :math.sin(ang) * 1.2, 1, a, ctx}
  end

  # ------------------------------------------------------------- forces

  defp flee_vector(a, neighbors, night) do
    detect = if night, do: @detect_pred * 0.68, else: @detect_pred

    Enum.reduce(neighbors, {0.0, 0.0, 0.0}, fn n, {fx, fz, p} = acc ->
      if n.species == 1 do
        d2 = dist2(a.x, a.z, n.x, n.z)

        if d2 < detect * detect do
          d = :math.sqrt(d2) + 0.001
          w = (detect - d) / detect
          {fx + (a.x - n.x) / d * w, fz + (a.z - n.z) / d * w, max(p, w)}
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp separation(a, neighbors) do
    Enum.reduce(neighbors, {0.0, 0.0}, fn n, {sx, sz} = acc ->
      if n.id != a.id and n.species == 0 do
        d2 = dist2(a.x, a.z, n.x, n.z)

        if d2 < @sep_r * @sep_r and d2 > 0.0001 do
          d = :math.sqrt(d2)
          {sx + (a.x - n.x) / d / d, sz + (a.z - n.z) / d / d}
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp alignment(a, neighbors) do
    {vx, vz, c} =
      Enum.reduce(neighbors, {0.0, 0.0, 0}, fn n, {vx, vz, c} = acc ->
        if n.id != a.id and n.species == 0 and
             dist2(a.x, a.z, n.x, n.z) < @ali_r * @ali_r do
          {vx + n.vx, vz + n.vz, c + 1}
        else
          acc
        end
      end)

    if c > 0, do: {vx / c - a.vx, vz / c - a.vz}, else: {0.0, 0.0}
  end

  defp cohesion(a, neighbors) do
    {x, z, c} =
      Enum.reduce(neighbors, {0.0, 0.0, 0}, fn n, {x, z, c} = acc ->
        if n.id != a.id and n.species == 0 and
             dist2(a.x, a.z, n.x, n.z) < @coh_r * @coh_r do
          {x + n.x, z + n.z, c + 1}
        else
          acc
        end
      end)

    if c > 2, do: {(x / c - a.x) * 0.15, (z / c - a.z) * 0.15}, else: {0.0, 0.0}
  end

  defp bounds_force(a) do
    m = 10.0
    fx = Const.field_x()
    fz = Const.field_z()

    bx =
      cond do
        a.x > fx - m -> -(a.x - (fx - m)) * 1.5
        a.x < -fx + m -> (-fx + m - a.x) * 1.5
        true -> 0.0
      end

    bz =
      cond do
        a.z > fz - m -> -(a.z - (fz - m)) * 1.5
        a.z < -fz + m -> (-fz + m - a.z) * 1.5
        true -> 0.0
      end

    # pond repulsion
    pf = Const.pond_field(a.x, a.z)

    {px, pz} =
      if pf < 1.6 do
        dx = a.x - Const.pond_cx()
        dz = a.z - Const.pond_cz()
        d = :math.sqrt(dx * dx + dz * dz) + 0.001
        w = (1.6 - pf) * 14.0
        {dx / d * w, dz / d * w}
      else
        {0.0, 0.0}
      end

    {bx + px, bz + pz}
  end

  # ------------------------------------------------------------- lifecycle

  defp maybe_reproduce(a, agents, ctx) do
    pop = ctx.herb_count
    damp = max(0.0, 1.0 - pop / Const.herb_cap())

    if a.energy > 190.0 and a.age > @adult_age * 0.8 and
         :rand.uniform() < 0.020 * ctx.dt * damp * 20 do
      calf = new(ctx.next_id, a.x + rnd(2), a.z + rnd(2), 0.0)
      calf = %{calf | energy: 95.0}
      parent = %{a | energy: a.energy - 85.0}
      agents = Map.put(agents, calf.id, calf)

      ctx = %{ctx | next_id: ctx.next_id + 1, agents: agents, herb_count: pop + 1}
      ctx = emit(ctx, {:birth, 0, a.x, a.z})
      {parent, ctx}
    else
      {a, %{ctx | agents: agents}}
    end
  end

  # ------------------------------------------------------------- utils

  defp emit(ctx, e), do: %{ctx | events: [e | ctx.events]}
  defp dist2(x1, z1, x2, z2), do: (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
  defp clamp(v, a, b), do: v |> max(a) |> min(b)
  defp rnd(s), do: (:rand.uniform() - 0.5) * 2 * s
end
