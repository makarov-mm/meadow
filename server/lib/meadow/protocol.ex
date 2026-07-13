defmodule Meadow.Protocol do
  @moduledoc """
  Binary frame, little-endian:

    header:  tick u32 | n_agents u16 | n_events u16 | grass_w u8 | grass_h u8
             | day_phase u16 | season_phase u16
    grass:   grass_w * grass_h bytes, amount 0..255
    agent:   id u16 | flags u8 | scale u8 | x i16 | z i16 | heading i16   (10 B)
    event:   type u8 | aux u8 | x i16 | z i16 | extra u16                 (8 B)

  Phases are 0..65535 mapped onto 0..1. flags: bits 0-1 species (0 herbivore,
  1 predator, 2 bush), bits 2-4 state (0 head down, 1 walk, 2 run, 3 dead,
  4 idle, 5 eat). scale: model scale * 200 for animals (calves grow), berries
  * 40 for bushes. Positions are fixed-point 1/64 m. Heading is rad * 10430.
  Event types: 0 kill, 1 birth (aux = species), 2 starvation (aux = species),
  3 berry eaten, 4 hunt started.
  """
  import Bitwise

  @max_events 200

  def encode(tick, day_phase, season_phase, grass, agents, bushes, events) do
    events = Enum.take(events, @max_events)
    grass_bin = Meadow.Food.encode(grass)

    abin =
      for {_id, a} <- agents, into: <<>>, do: agent_bin(a)

    bbin =
      for b <- bushes, into: <<>>, do: bush_bin(b)

    ebin = for e <- events, into: <<>>, do: event_bin(e)

    n = map_size(agents) + length(bushes)
    dp = trunc(day_phase * 65535)
    sp = trunc(season_phase * 65535)

    <<tick::32-little, n::16-little, length(events)::16-little, Meadow.Const.grass_w()::8,
      Meadow.Const.grass_h()::8, dp::16-little, sp::16-little>> <> grass_bin <> abin <> bbin <>
      ebin
  end

  defp agent_bin(a) do
    flags = a.species ||| a.state <<< 2

    scale =
      case a.species do
        0 -> trunc(Meadow.Herbivore.scale(a) * 200)
        _ -> 200
      end

    <<a.id::16-little, flags::8, scale::8, fp(a.x)::16-little-signed, fp(a.z)::16-little-signed,
      hfp(a.heading)::16-little-signed>>
  end

  defp bush_bin(b) do
    flags = 2
    scale = min(b.berries * 40, 255)

    <<b.id::16-little, flags::8, scale::8, fp(b.x)::16-little-signed, fp(b.z)::16-little-signed,
      hfp(b.heading)::16-little-signed>>
  end

  defp event_bin({type, aux, x, z}) do
    code =
      case type do
        :kill -> 0
        :birth -> 1
        :starve -> 2
        :berry -> 3
        :hunt -> 4
      end

    <<code::8, aux::8, fp(x)::16-little-signed, fp(z)::16-little-signed, 0::16>>
  end

  defp fp(v), do: v |> Kernel.*(64) |> round() |> max(-32000) |> min(32000)

  defp hfp(h) do
    tau = 2 * :math.pi()
    h = :math.fmod(h, tau)
    h = if h > :math.pi(), do: h - tau, else: h
    h = if h < -:math.pi(), do: h + tau, else: h
    h |> Kernel.*(10430) |> round() |> max(-32760) |> min(32760)
  end
end
