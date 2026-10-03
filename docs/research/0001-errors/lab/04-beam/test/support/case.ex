defmodule BeamLab.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import BeamLab.Case
      alias BeamLab.Capture
    end
  end

  setup do
    id = BeamLab.Capture.attach()
    on_exit(fn -> :logger.remove_handler(id) end)
    # drain anything logged before the handler existed
    BeamLab.Capture.collect(20)
    :ok
  end

  def crash(:raise), do: raise("boom")
  def crash(:throw), do: throw(:boom)
  def crash(:exit), do: exit(:boom)
  def crash(:badarg), do: :erlang.atom_to_binary(Process.get(:not_set, 1))

  @doc "Run fun, collect events, dump them under the test name."
  def run(name, fun, ms \\ 250) do
    fun.()
    BeamLab.Capture.collect(ms) |> BeamLab.Capture.dump(name)
  end

  def errors(events), do: Enum.filter(events, &(&1.level in [:error, :critical, :alert, :emergency]))

  def report(%{msg: {:report, r}}), do: r
  def report(_), do: nil
end
