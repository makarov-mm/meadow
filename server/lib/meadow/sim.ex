defmodule Meadow.Sim do
  @moduledoc """
  The ecosystem heartbeat. One GenServer, fixed tick, flat agent map. Each
  tick: grass regrows, bushes refill, every animal steps (herbivores flock and
  graze, predators hunt), corpses decay, populations are counted, and a safety
  net tops up either species if it collapses (a small group migrates in from
  the field edge, so the scene never dies).

  TICK_MS can be lowered via environment for accelerated headless balance
  testing; the simulation dt stays fixed, so a 10 ms tick runs the ecology at
  5x wall speed.
  """
  use GenServer

  alias Meadow.{Const, Food, Grid, Herbivore, Predator}

  @dt 0.05
  @corpse_keep 7.0
  @init_herds 3
  @herd_size 42
  @init_wolves 4
  @bush_count 12

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    tick_ms = String.to_integer(System.get_env("TICK_MS", "50"))

    {bushes, next_id} = Food.spawn_bushes(@bush_count, 1)

    {agents, next_id} =
      Enum.reduce(1..@init_herds, {%{}, next_id}, fn _, acc ->
        spawn_herd(acc, @herd_size)
      end)

    {agents, next_id} =
      Enum.reduce(1..@init_wolves, {agents, next_id}, fn _, {ags, id} ->
        {x, z} = Food.land_spot()
        {Map.put(ags, id, Predator.new(id, x, z)), id + 1}
      end)

    state = %{
      tick: 0,
      tick_ms: tick_ms,
      agents: agents,
      bushes: bushes,
      grass: Food.new_grass(),
      next_id: next_id,
      events: [],
      migrate_check: 0.0,
      stats: %{kill: 0, hunt: 0, starve_h: 0, starve_p: 0, birth_h: 0, birth_p: 0}
    }

    schedule(tick_ms)
    {:ok, state}
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp spawn_herd({agents, next_id}, size) do
    {hx, hz} = Food.land_spot()

    Enum.reduce(1..size, {agents, next_id}, fn _, {ags, id} ->
      x = hx + (:rand.uniform() - 0.5) * 24
      z = hz + (:rand.uniform() - 0.5) * 24
      {Map.put(ags, id, Herbivore.new(id, x, z)), id + 1}
    end)
  end

  @impl true
  def handle_info(:tick, s) do
    grass = Food.regrow(s.grass, @dt)
    bushes = Enum.map(s.bushes, &Food.bush_tick(&1, @dt))
    grid = Grid.build(s.agents)

    herb_count = Enum.count(s.agents, fn {_, a} -> a.species == 0 and a.state != 3 end)
    pred_count = Enum.count(s.agents, fn {_, a} -> a.species == 1 and a.state != 3 end)

    ctx = %{
      dt: @dt,
      grid: grid,
      agents: s.agents,
      grass: grass,
      bushes: bushes,
      events: s.events,
      next_id: s.next_id,
      herb_count: herb_count,
      pred_count: pred_count
    }

    ctx = step_all(ctx)
    ctx = decay_corpses(ctx)
    ctx = migration_safety(ctx, s)

    stats =
      Enum.reduce(ctx.events, s.stats, fn
        {:kill, _, _, _}, st -> %{st | kill: st.kill + 1}
        {:hunt, _, _, _}, st -> %{st | hunt: st.hunt + 1}
        {:starve, 0, _, _}, st -> %{st | starve_h: st.starve_h + 1}
        {:starve, 1, _, _}, st -> %{st | starve_p: st.starve_p + 1}
        {:birth, 0, _, _}, st -> %{st | birth_h: st.birth_h + 1}
        {:birth, 1, _, _}, st -> %{st | birth_p: st.birth_p + 1}
        _, st -> st
      end)

    frame =
      Meadow.Protocol.encode(
        s.tick,
        ctx.grass,
        ctx.agents,
        ctx.bushes,
        Enum.reverse(ctx.events)
      )

    Registry.dispatch(Meadow.Clients, :ws, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:frame, frame})
    end)

    schedule(s.tick_ms)

    {:noreply,
     %{
       s
       | tick: s.tick + 1,
         agents: ctx.agents,
         bushes: ctx.bushes,
         grass: ctx.grass,
         next_id: ctx.next_id,
         events: [],
         migrate_check: ctx.migrate_check,
         stats: stats
     }}
  end

  defp step_all(ctx) do
    Enum.reduce(Map.keys(ctx.agents), ctx, fn id, ctx ->
      case ctx.agents[id] do
        nil ->
          ctx

        %{state: 3} ->
          ctx

        %{species: 0} = a ->
          {a2, ctx2} = Herbivore.step(a, ctx)
          %{ctx2 | agents: Map.put(ctx2.agents, id, a2)}

        %{species: 1} = a ->
          {a2, ctx2} = Predator.step(a, ctx)
          %{ctx2 | agents: Map.put(ctx2.agents, id, a2)}

        _ ->
          ctx
      end
    end)
  end

  defp decay_corpses(ctx) do
    agents =
      ctx.agents
      |> Enum.reduce(%{}, fn {id, a}, acc ->
        if a.state == 3 do
          t = a.corpse_t + ctx.dt
          if t >= @corpse_keep, do: acc, else: Map.put(acc, id, %{a | corpse_t: t})
        else
          Map.put(acc, id, a)
        end
      end)

    %{ctx | agents: agents}
  end

  # If a species collapses, a small group wanders in from the field edge.
  defp migration_safety(ctx, s) do
    check = Map.get(s, :migrate_check, 0.0) + ctx.dt
    ctx = Map.put(ctx, :migrate_check, check)

    if check < 8.0 do
      ctx
    else
      ctx = Map.put(ctx, :migrate_check, 0.0)

      ctx =
        if ctx.herb_count < Const.herb_min() do
          {agents, next_id} =
            Enum.reduce(1..10, {ctx.agents, ctx.next_id}, fn _, {ags, id} ->
              {x, z} = edge_spot()
              {Map.put(ags, id, Herbivore.new(id, x, z)), id + 1}
            end)

          %{ctx | agents: agents, next_id: next_id, herb_count: ctx.herb_count + 10}
        else
          ctx
        end

      if ctx.pred_count < Const.pred_min() do
        {x, z} = edge_spot()
        agents = Map.put(ctx.agents, ctx.next_id, Predator.new(ctx.next_id, x, z))
        %{ctx | agents: agents, next_id: ctx.next_id + 1, pred_count: ctx.pred_count + 1}
      else
        ctx
      end
    end
  end

  defp edge_spot do
    if :rand.uniform() < 0.5 do
      {Enum.random([-1, 1]) * (Const.field_x() - 6), (:rand.uniform() - 0.5) * 2 * Const.field_z()}
    else
      {(:rand.uniform() - 0.5) * 2 * Const.field_x(), Enum.random([-1, 1]) * (Const.field_z() - 6)}
    end
  end
end
