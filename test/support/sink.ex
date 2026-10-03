defmodule Blackbox.Sink do
  @moduledoc "Test writer: forwards every batch to a pid."
  alias Blackbox.Buffer

  def to(pid) do
    fn batch ->
      send(pid, {:batch, batch})
      :ok
    end
  end

  def attach, do: Buffer.set_writer(to(self()))

  # Everything written within `ms`, merged by fingerprint.
  def collect(ms \\ 300) do
    Buffer.flush()
    Process.sleep(ms)
    Buffer.flush()
    Process.sleep(20)

    drain([])
    |> Enum.group_by(& &1.fingerprint)
    |> Enum.map(fn {_, [i | _] = is} ->
      %{i | count: Enum.sum(Enum.map(is, & &1.count)), samples: Enum.flat_map(is, & &1.samples)}
    end)
  end

  defp drain(acc) do
    receive do
      {:batch, b} -> drain(acc ++ b)
    after
      50 -> acc
    end
  end

  def types(issues), do: issues |> Enum.map(&{&1.type, &1.count}) |> Enum.sort()
end
