defmodule Meadow.Grid do
  @moduledoc """
  Coarse spatial hash for neighborhood queries. Flocking needs neighbors every
  tick; a naive all-pairs scan is O(n^2) and gets expensive past a couple
  hundred animals. Bucketing into 8 m cells makes each query touch at most
  nine buckets.
  """

  @cell 8.0

  @doc "Buckets living animals (herbivores and predators) by cell."
  def build(agents) do
    Enum.reduce(agents, %{}, fn {_, a}, acc ->
      if a.species == 2 or a.state == 3 do
        acc
      else
        Map.update(acc, key(a.x, a.z), [a], &[a | &1])
      end
    end)
  end

  @doc "All living animals in the 3x3 cell neighborhood around (x, z)."
  def nearby(grid, x, z) do
    {kx, kz} = key(x, z)

    Enum.reduce(-1..1, [], fn dx, acc ->
      Enum.reduce(-1..1, acc, fn dz, acc2 ->
        case Map.get(grid, {kx + dx, kz + dz}) do
          nil -> acc2
          list -> list ++ acc2
        end
      end)
    end)
  end

  defp key(x, z), do: {trunc(Float.floor(x / @cell)), trunc(Float.floor(z / @cell))}
end
