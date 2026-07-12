defmodule Meadow.Food do
  @moduledoc """
  Food layer: a grass grid that regrows logistically and berry bushes that
  refill one berry at a time. Grass amounts are 0..1 per cell; grazed areas
  visibly go brown on the client and green back over time.
  """
  alias Meadow.Const

  @regrow 0.035
  @seed 0.02

  def new_grass do
    n = Const.grass_w() * Const.grass_h()
    List.to_tuple(for _ <- 1..n, do: 0.75 + :rand.uniform() * 0.25)
  end

  def cell_index(x, z) do
    gw = Const.grass_w()
    gh = Const.grass_h()
    cx = trunc((x + Const.field_x()) / (2 * Const.field_x()) * gw)
    cz = trunc((z + Const.field_z()) / (2 * Const.field_z()) * gh)
    cx = min(max(cx, 0), gw - 1)
    cz = min(max(cz, 0), gh - 1)
    cz * gw + cx
  end

  def amount_at(grass, x, z), do: elem(grass, cell_index(x, z))

  def graze(grass, x, z, want) do
    i = cell_index(x, z)
    a = elem(grass, i)
    eaten = min(a, want)
    {put_elem(grass, i, a - eaten), eaten}
  end

  def regrow(grass, dt) do
    n = tuple_size(grass)

    List.to_tuple(
      for i <- 0..(n - 1) do
        a = max(elem(grass, i), @seed)
        min(a + @regrow * a * (1.0 - a) * dt, 1.0)
      end
    )
  end

  def encode(grass) do
    n = tuple_size(grass)
    for i <- 0..(n - 1), into: <<>>, do: <<trunc(elem(grass, i) * 255)::8>>
  end

  @doc "Initial berry bushes, placed on land away from the pond."
  def spawn_bushes(count, next_id) do
    Enum.map_reduce(1..count, next_id, fn _, id ->
      {x, z} = land_spot()

      bush = %{
        id: id,
        species: 2,
        state: 0,
        x: x,
        z: z,
        heading: :rand.uniform() * 6.28,
        berries: 3 + :rand.uniform(3),
        regrow_t: 0.0
      }

      {bush, id + 1}
    end)
  end

  def bush_tick(bush, dt) do
    if bush.berries < 6 do
      t = bush.regrow_t + dt

      if t >= 12.0 do
        %{bush | berries: bush.berries + 1, regrow_t: 0.0}
      else
        %{bush | regrow_t: t}
      end
    else
      bush
    end
  end

  def land_spot do
    x = (:rand.uniform() - 0.5) * 2 * (Const.field_x() - 12)
    z = (:rand.uniform() - 0.5) * 2 * (Const.field_z() - 10)
    if Const.pond_field(x, z) < 1.5, do: land_spot(), else: {x, z}
  end
end
