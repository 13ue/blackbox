defmodule BeforeLab.Echo do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(s), do: {:ok, s}
  def handle_call(m, _f, s), do: {:reply, m, s}
end

defmodule BeforeLab.LabPlug do
  @moduledoc "A request with realistic 'before' material: 5 debug logs, 3 fake queries, 1 GenServer call."
  import Plug.Conn
  require Logger

  def init(o), do: o

  def call(%{path_info: ["whoami"]} = conn, _),
    do: send_resp(conn, 200, :erlang.term_to_binary({self(), BeforeLab.Ring.Pdict.read(), :seq_trace.get_token(:label)}))

  def call(%{path_info: ["crash"]} = conn, _) do
    Logger.debug("about to crash", path: conn.request_path)
    raise "plug boom"
  end

  def call(conn, _) do
    for i <- 1..5, do: Logger.debug("step #{i}", user_id: 42)
    for _ <- 1..3, do: :telemetry.execute([:lab, :repo, :query], %{total_time: 1000}, %{source: "users"})
    :pong = GenServer.call(BeforeLab.Echo, :pong)
    send_resp(conn, 200, "ok")
  end
end

defmodule BeforeLab.Capture2 do
  @moduledoc "The 'full capture' setup: crumbs from Logger (all levels) and telemetry into the pdict ring, a seq_trace request label, cleared at request start."
  alias BeforeLab.Ring

  def on(parts \\ [:logger, :handler, :telemetry]) do
    if :logger in parts, do: :logger.set_primary_config(:level, :debug)
    if :handler in parts, do: :ok = :logger.add_handler(:crumbs, BeforeLab.CrumbHandler, %{level: :all})
    if :telemetry in parts, do: attach()
  end

  defp attach do
    :telemetry.attach_many(:lab_crumbs, [[:lab, :repo, :query], [:bandit, :request, :stop]], &__MODULE__.crumb/4, nil)
    :telemetry.attach(:lab_start, [:bandit, :request, :start], &__MODULE__.start/4, nil)
  end

  def off do
    :logger.set_primary_config(:level, :info)
    :logger.remove_handler(:crumbs)
    :telemetry.detach(:lab_crumbs)
    :telemetry.detach(:lab_start)
  end

  def start(_e, _m, _meta, _) do
    Ring.Pdict.clear()
    :seq_trace.set_token(:label, :erlang.unique_integer([:positive]))
  end

  def crumb(e, m, _meta, _), do: Ring.Pdict.add({System.monotonic_time(), e, m})
end
