defmodule BeforeLab.TelemetryTest do
  use ExUnit.Case, async: false
  alias BeforeLab.Ring

  setup do
    Ring.Pdict.clear()
    on_exit(fn -> for %{id: id} <- :telemetry.list_handlers([]), match?({:lab, _}, id), do: :telemetry.detach(id) end)
    :ok
  end

  def crumb(event, measurements, _meta, _config), do: Ring.Pdict.add({event, measurements})

  test "06-18: a telemetry handler runs in the emitting process and fills that process's ring" do
    :telemetry.attach({:lab, 1}, [:repo, :query], &__MODULE__.crumb/4, nil)
    t = Task.async(fn -> :telemetry.execute([:repo, :query], %{total_time: 5}, %{}); Ring.Pdict.read() end)
    assert Task.await(t) == [{[:repo, :query], %{total_time: 5}}]
    assert Ring.Pdict.read() == []
  end

  test "06-19: a raising telemetry handler is detached and [:telemetry, :handler, :failure] fires" do
    me = self()
    :telemetry.attach({:lab, :bad}, [:x], fn _, _, _, _ -> raise "oops" end, nil)
    :telemetry.attach({:lab, :watch}, [:telemetry, :handler, :failure], fn _, _, m, _ -> send(me, {:failed, m.handler_id}) end, nil)
    :telemetry.execute([:x], %{}, %{})
    assert_received {:failed, {:lab, :bad}}
    refute Enum.any?(:telemetry.list_handlers([:x]), &(&1.id == {:lab, :bad}))
  end

  test "06-20: there is no prefix/wildcard attach: [:repo] does not see [:repo, :query]" do
    :telemetry.attach({:lab, 2}, [:repo], &__MODULE__.crumb/4, nil)
    :telemetry.execute([:repo, :query], %{}, %{})
    assert Ring.Pdict.read() == []
  end

  test "06-21: list_handlers([]) reveals every event name someone attached to (a discovery trick)" do
    :telemetry.attach({:lab, 3}, [:my_app, :thing, :stop], &__MODULE__.crumb/4, nil)
    names = for %{event_name: e} <- :telemetry.list_handlers([]), do: e
    assert [:my_app, :thing, :stop] in names
  end
end
