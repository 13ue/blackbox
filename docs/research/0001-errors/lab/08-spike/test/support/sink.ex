defmodule Spike.Sink do
  @moduledoc "Test writer: forwards every batch to a pid."
  def to(pid), do: fn batch -> send(pid, {:batch, batch}); :ok end

  def collect(ms \\ 300) do
    Spike.Buffer.flush()
    Process.sleep(ms)
    Spike.Buffer.flush()
    drain([])
  end

  defp drain(acc) do
    receive do
      {:batch, b} -> drain(acc ++ b)
    after 50 -> acc
    end
  end
end
