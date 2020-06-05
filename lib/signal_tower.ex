defmodule SignalTower do
  use Application
  require Logger

  alias SignalTower.{WebsocketHandler, PrometheusHTTPHandler, Room, Stats}

  @impl Application
  def start(_type, _args) do
    start_cowboy()
    |> start_supervisor()
  end

  @impl Application
  def stop(_state) do
    :ok
  end

  defp start_cowboy() do
    ip =
      if System.get_env("SIGNALTOWER_LOCALHOST") do
        {127, 0, 0, 1}
      else
        {0, 0, 0, 0}
      end

    {port, _} = Integer.parse(System.get_env("SIGNALTOWER_PORT") || "4233")

    dispatch =
      :cowboy_router.compile([
        {"localhost",
         [
           {"/", WebsocketHandler, []},
           {"/metrics", PrometheusHTTPHandler, []}
         ]},
        {:_, [{"/", WebsocketHandler, []}]}
      ])

    {ip, port, dispatch}
  end

  defp start_supervisor({ip, port, dispatch}) do
    children = [
      {DynamicSupervisor, name: Room.Supervisor, strategy: :one_for_one},
      {Stats, []},
      %{
        id: :cowboy,
        start:
          {:cowboy, :start_clear, [:http, [ip: ip, port: port], %{env: %{dispatch: dispatch}}]}
      }
    ]

    ret = Supervisor.start_link(children, strategy: :one_for_one)
    Logger.info("SignalTower started")
    ret
  end
end
