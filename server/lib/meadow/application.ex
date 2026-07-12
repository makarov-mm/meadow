defmodule Meadow.Application do
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4041"))

    children = [
      {Registry, keys: :duplicate, name: Meadow.Clients},
      Meadow.Sim,
      {Meadow.WS, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Meadow.Supervisor)
  end
end
