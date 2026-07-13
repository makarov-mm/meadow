defmodule Meadow.Predator do
  @moduledoc """
  Predator (wolf) behavior. Wolves hunt alone. Target choice favors isolated
  prey: distance is weighted up by the number of herd neighbors around each
  candidate, so stragglers and edge animals get picked first.

  The chase is a sprint with limited stamina. A sprinting wolf outruns a deer;
  a tired wolf does not. That asymmetry produces natural hunt outcomes: herds
  escape, loners get caught.
  """
  alias Meadow.Const

  @hungry_below 165.0
  @sprint_speed 8.8
  @tired_speed 3.0
  @walk_speed 2.0
  @catch_dist 1.7
  @give_up_dist 55.0
  @eat_time 4.5

  def new(id, x, z) do
    %{
      id: id,
      species: 1,
      state: 4,
      x: x,
      z: z,
      vx: 0.0,
      vz: 0.0,
      heading: :rand.uniform() * 6.28,
      energy: 170.0 + :rand.uniform() * 50,
      age: 10.0,
      max_age: 200.0 + :rand.uniform() * 140.0,
      stamina: 100.0,
      target: nil,
      eat_t: 0.0,
      corpse_t: 0.0
    }
  end

  def scale(_a), do: 1.0

  def step(a, ctx) do
    case a.state do
      # eating at a kill
      5 ->
        eat_t = a.eat_t + ctx.dt

        if eat_t >= @eat_time do
          {%{a | state: 4, eat_t: 0.0, target: nil}, ctx}
        else
          {%{a | eat_t: eat_t, energy: min(a.energy + 32.0 * ctx.dt, 255.0)}, ctx}
        end

      _ ->
        live(a, ctx)
    end
  end

  defp live(a, ctx) do
    threshold = if ctx.night, do: @hungry_below + 40.0, else: @hungry_below
    hungry = a.energy < threshold

    {a, ctx} =
      cond do
        a.target != nil ->
          chase(a, ctx)

        hungry and a.stamina > 55.0 ->
          acquire_target(a, ctx)

        true ->
          {wander(a, ctx.dt), ctx}
      end

    a = integrate(a, ctx.dt)

    # stamina regen while not sprinting
    a =
      if a.state == 2 do
        a
      else
        %{a | stamina: min(a.stamina + 9.0 * ctx.dt, 100.0)}
      end

    drain = if a.state == 2, do: 2.6, else: 0.85
    energy = a.energy - drain * ctx.dt
    a = %{a | energy: energy, age: a.age + ctx.dt}

    cond do
      energy <= 0 ->
        ctx = emit(ctx, {:starve, 1, a.x, a.z})
        {%{a | state: 3, corpse_t: 0.0}, ctx}

      a.age > a.max_age ->
        ctx = emit(ctx, {:starve, 1, a.x, a.z})
        {%{a | state: 3, corpse_t: 0.0}, ctx}

      true ->
        maybe_reproduce(a, ctx)
    end
  end

  defp acquire_target(a, ctx) do
    prey =
      for {_, p} <- ctx.agents,
          p.species == 0,
          p.state != 3,
          d2 = dist2(a.x, a.z, p.x, p.z),
          d2 < 26.0 * 26.0 do
        crowd = herd_neighbors(ctx.grid, p)
        size = Meadow.Herbivore.scale(p)
        {p.id, d2 * (1.0 + 0.25 * crowd) * (0.55 + 0.45 * size)}
      end

    case prey do
      [] ->
        {stalk(a, ctx), ctx}

      list ->
        {id, _} = Enum.min_by(list, &elem(&1, 1))
        ctx = emit(ctx, {:hunt, 0, a.x, a.z})
        {%{a | target: id, state: 2}, ctx}
    end
  end

  # No prey close enough for a sprint: walk toward the nearest herd instead
  # of wandering blindly. Keeps encounter rate up on a large field.
  defp stalk(a, ctx) do
    nearest =
      Enum.reduce(ctx.agents, nil, fn
        {_, %{species: 0, state: st} = p}, best when st != 3 ->
          d2 = dist2(a.x, a.z, p.x, p.z)

          case best do
            nil -> {p, d2}
            {_, bd} when d2 < bd -> {p, d2}
            _ -> best
          end

        _, best ->
          best
      end)

    case nearest do
      nil ->
        wander(a, ctx.dt)

      {p, _} ->
        dx = p.x - a.x
        dz = p.z - a.z
        d = :math.sqrt(dx * dx + dz * dz) + 0.001

        %{
          a
          | vx: a.vx * 0.9 + dx / d * 4.0 * ctx.dt,
            vz: a.vz * 0.9 + dz / d * 4.0 * ctx.dt,
            state: 1
        }
    end
  end

  defp herd_neighbors(grid, p) do
    Meadow.Grid.nearby(grid, p.x, p.z)
    |> Enum.count(fn n -> n.species == 0 and n.id != p.id and dist2(n.x, n.z, p.x, p.z) < 100.0 end)
  end

  defp chase(a, ctx) do
    case ctx.agents[a.target] do
      nil ->
        {%{a | target: nil, state: 1}, ctx}

      %{state: 3} ->
        {%{a | target: nil, state: 1}, ctx}

      prey ->
        d2 = dist2(a.x, a.z, prey.x, prey.z)
        d = :math.sqrt(d2)

        cond do
          d < @catch_dist ->
            kill(a, prey, ctx)

          d > @give_up_dist or (a.stamina <= 0.0 and d > 9.0) ->
            {%{a | target: nil, state: 1}, ctx}

          true ->
            # lead the target a little
            tx = prey.x + prey.vx * 0.45
            tz = prey.z + prey.vz * 0.45
            dx = tx - a.x
            dz = tz - a.z
            dd = :math.sqrt(dx * dx + dz * dz) + 0.001

            sprinting = a.stamina > 0.0
            stamina = max(a.stamina - (if sprinting, do: 9.0, else: 0.0) * ctx.dt, 0.0)
            sp = if sprinting, do: @sprint_speed, else: @tired_speed

            # Velocity targeting: converge to full chase speed. Integrating
            # forces here is a trap: with per-tick damping the equilibrium
            # speed sits far below the cap and the wolf never catches anyone.
            k = 0.30

            a = %{
              a
              | vx: a.vx * (1 - k) + dx / dd * sp * k,
                vz: a.vz * (1 - k) + dz / dd * sp * k,
                stamina: stamina,
                state: 2
            }

            {a, ctx}
        end
    end
  end

  defp kill(a, prey, ctx) do
    agents = Map.put(ctx.agents, prey.id, %{prey | state: 3, corpse_t: 0.0})
    ctx = %{ctx | agents: agents, herb_count: ctx.herb_count - 1}
    ctx = emit(ctx, {:kill, 0, prey.x, prey.z})

    a = %{a | state: 5, eat_t: 0.0, energy: min(a.energy + 120.0, 255.0), vx: 0.0, vz: 0.0}
    {a, ctx}
  end

  defp wander(a, dt) do
    ang = a.heading + (:rand.uniform() - 0.5) * 0.9
    %{a | vx: a.vx * 0.9 + :math.cos(ang) * 3.0 * dt, vz: a.vz * 0.9 + :math.sin(ang) * 3.0 * dt, state: 1}
  end

  defp integrate(a, dt) do
    {bx, bz} = bounds_force(a)
    vx = a.vx + bx * dt
    vz = a.vz + bz * dt

    cap =
      case a.state do
        2 -> if a.stamina > 0.0, do: @sprint_speed, else: @tired_speed
        5 -> 0.0
        _ -> @walk_speed
      end

    sp = :math.sqrt(vx * vx + vz * vz)
    {vx, vz} = if sp > cap, do: {vx / sp * cap, vz / sp * cap}, else: {vx, vz}

    x = clamp(a.x + vx * dt, -Const.field_x(), Const.field_x())
    z = clamp(a.z + vz * dt, -Const.field_z(), Const.field_z())
    heading = if sp > 0.2, do: :math.atan2(vz, vx), else: a.heading

    %{a | x: x, z: z, vx: vx, vz: vz, heading: heading}
  end

  defp bounds_force(a) do
    m = 8.0
    fx = Const.field_x()
    fz = Const.field_z()

    bx =
      cond do
        a.x > fx - m -> -(a.x - (fx - m)) * 2.0
        a.x < -fx + m -> (-fx + m - a.x) * 2.0
        true -> 0.0
      end

    bz =
      cond do
        a.z > fz - m -> -(a.z - (fz - m)) * 2.0
        a.z < -fz + m -> (-fz + m - a.z) * 2.0
        true -> 0.0
      end

    pf = Const.pond_field(a.x, a.z)

    {px, pz} =
      if pf < 1.6 do
        dx = a.x - Const.pond_cx()
        dz = a.z - Const.pond_cz()
        d = :math.sqrt(dx * dx + dz * dz) + 0.001
        w = (1.6 - pf) * 16.0
        {dx / d * w, dz / d * w}
      else
        {0.0, 0.0}
      end

    {bx + px, bz + pz}
  end

  defp maybe_reproduce(a, ctx) do
    damp = max(0.0, 1.0 - ctx.pred_count / Const.pred_cap())

    if a.energy > 210.0 and :rand.uniform() < 0.010 * ctx.dt * damp * 20 do
      pup = new(ctx.next_id, a.x + rnd(2), a.z + rnd(2))
      pup = %{pup | energy: 120.0}
      parent = %{a | energy: a.energy - 90.0}
      agents = Map.put(ctx.agents, pup.id, pup)

      ctx = %{ctx | next_id: ctx.next_id + 1, agents: agents, pred_count: ctx.pred_count + 1}
      ctx = emit(ctx, {:birth, 1, a.x, a.z})
      {parent, ctx}
    else
      {a, ctx}
    end
  end

  defp emit(ctx, e), do: %{ctx | events: [e | ctx.events]}
  defp dist2(x1, z1, x2, z2), do: (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
  defp clamp(v, a, b), do: v |> max(a) |> min(b)
  defp rnd(s), do: (:rand.uniform() - 0.5) * 2 * s
end
