defmodule Meadow.Const do
  @moduledoc """
  World constants shared across simulation modules. The client hardcodes the
  matching field and pond values, so change them in both places.
  """

  def field_x, do: 140.0
  def field_z, do: 90.0

  # Pond: an ellipse animals will not enter.
  def pond_cx, do: 34.0
  def pond_cz, do: -18.0
  def pond_rx, do: 20.0
  def pond_rz, do: 13.0

  def grass_w, do: 36
  def grass_h, do: 24

  def herb_cap, do: 240
  def pred_cap, do: 12

  def herb_min, do: 12
  def pred_min, do: 2

  # World clock. A full day lasts @day_len sim-seconds (roughly two thirds
  # daylight, one third night via the sun elevation curve). A season sweep
  # takes @season_len sim-seconds: the fertile band crosses the field and
  # comes back, so one full migration cycle per season period.
  def day_len, do: 180.0
  def season_len, do: 600.0

  @doc "0..1 phase of the day. 0 is dawn, 0.25 noon, 0.5 dusk, 0.75 midnight."
  def day_phase(world_t), do: :math.fmod(world_t, day_len()) / day_len()

  @doc "0..1 phase of the season cycle."
  def season_phase(world_t), do: :math.fmod(world_t, season_len()) / season_len()

  @doc "Sun elevation, -1..1. Negative is night."
  def sun_elevation(day_phase), do: :math.sin(2 * :math.pi() * day_phase)

  def night?(day_phase), do: sun_elevation(day_phase) < -0.08

  @doc "Signed pond field: < 1 inside the ellipse."
  def pond_field(x, z) do
    dx = (x - pond_cx()) / pond_rx()
    dz = (z - pond_cz()) / pond_rz()
    dx * dx + dz * dz
  end
end
