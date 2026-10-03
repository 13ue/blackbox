defmodule Lab01.FakeClient do
  @behaviour Sentry.HTTPClient
  @impl true
  def post(_url, _headers, _body) do
    # a slow Sentry, when a test asks for one
    Process.sleep(:persistent_term.get(:lab01_delay, 0))
    {:ok, 200, [], ~s({"id":"fake"})}
  end
end

defmodule Lab01.Collector do
  # Events go to whatever pid is registered as :lab01_sink.
  def before_send(event) do
    if pid = Process.whereis(:lab01_sink), do: send(pid, {:captured, event})
    event
  end

  def after_send(event, _result) do
    if pid = Process.whereis(:lab01_sink), do: send(pid, {:sent, event})
    :ok
  end
end
