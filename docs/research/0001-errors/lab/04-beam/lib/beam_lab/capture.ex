defmodule BeamLab.Capture do
  @moduledoc "Test :logger handler: forwards every event (and the pid it ran in) to a test pid."

  def log(event, %{config: %{to: to}}) do
    # also report what Process.get sees where the handler runs
    send(to, {:log_event, Map.put(event, :handler_dict_marker, Process.get(:lab_marker)), self()})
  end

  def attach(to \\ self()) do
    id = :"cap#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{level: :all, config: %{to: to}})
    id
  end

  @doc "Collect events until the mailbox is quiet for `ms`."
  def collect(ms \\ 250), do: collect(ms, [])

  defp collect(ms, acc) do
    receive do
      {:log_event, e, h} -> collect(ms, [Map.put(e, :handler_pid, h) | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  @doc "A short, stable description of an event for the log files."
  def shape(%{level: l, msg: msg, meta: meta}) do
    {kind, label} =
      case msg do
        {:report, %{label: label}} -> {:report_map, label}
        {:report, r} when is_map(r) -> {:report_map, Map.keys(r) -- [:elixir_translation]}
        {:report, r} when is_list(r) -> {:report_list, Keyword.keys(r) -- [:elixir_translation]}
        {:string, s} -> {:string, IO.iodata_to_binary(s) |> String.slice(0, 60)}
        {f, _} -> {:format, f |> to_string() |> String.slice(0, 40)}
      end

    %{level: l, domain: meta[:domain], kind: kind, label: label,
      meta: meta |> Map.keys() |> Enum.sort()}
  end

  def dump(events, name) do
    File.write!(Path.expand("../../../../logs/04-events.log", __DIR__),
      "\n== #{name}\n" <> Enum.map_join(events, "\n", &inspect(shape(&1), limit: 50)) <> "\n",
      [:append])
    events
  end
end
