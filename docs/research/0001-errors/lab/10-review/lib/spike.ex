defmodule Spike do
  @moduledoc "Spike of an error tracker core: capture -> bounded buffer -> writer -> Postgres."
  @stats [:dropped, :handler_errors, :writer_failures, :captured, :inflight]

  def crumb(message), do: Spike.Crumbs.add(:crumb, message)

  def stats, do: Map.new(Enum.with_index(@stats, 1), fn {k, i} -> {k, :atomics.get(ref(), i)} end)
  def bump(key, n \\ 1), do: :atomics.add_get(ref(), index(key), n)

  def ref do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> r = :atomics.new(length(@stats), signed: true); :persistent_term.put(__MODULE__, r); r
      r -> r
    end
  end

  for {k, i} <- Enum.with_index(@stats, 1), do: defp(index(unquote(k)), do: unquote(i))
end
