defmodule Meadow.MixProject do
  use Mix.Project

  def project do
    [
      app: :meadow,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Meadow.Application, []}
    ]
  end
end
