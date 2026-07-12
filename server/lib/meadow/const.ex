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
  def pred_cap, do: 14

  def herb_min, do: 12
  def pred_min, do: 2

  @doc "Signed pond field: < 1 inside the ellipse."
  def pond_field(x, z) do
    dx = (x - pond_cx()) / pond_rx()
    dz = (z - pond_cz()) / pond_rz()
    dx * dx + dz * dz
  end
end
