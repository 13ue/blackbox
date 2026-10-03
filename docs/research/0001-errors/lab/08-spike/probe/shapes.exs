defmodule P do
  def log(ev, %{config: %{to: to}}), do: send(to, {:ev, self(), ev})
end
:logger.add_handler(:probe, P, %{level: :all, config: %{to: self()}})
:logger.remove_handler(:default)
defmodule G do
  use GenServer
  def init(x), do: {:ok, x}
  def handle_call(:boom, _, s), do: {:reply, raise("gs boom"), s}
end
drain = fn tag ->
  Process.sleep(200)
  receive_all = fn f, acc -> receive do {:ev, p, e} -> f.(f, [{p, e} | acc]) after 0 -> Enum.reverse(acc) end end
  for {p, e} <- receive_all.(receive_all, []) do
    IO.puts("== #{tag} handler_pid=#{inspect p} level=#{e.level} meta_keys=#{inspect Map.keys(e.meta)} domain=#{inspect e.meta[:domain]} crash_reason?=#{Map.has_key?(e.meta, :crash_reason)}")
    IO.puts(String.slice(inspect(e.msg, limit: 12, printable_limit: 60), 0, 900))
  end
end
spawn(fn -> Process.put(:crumbs, [:a]); Process.set_label(:lbl); raise "plain spawn" end); drain.("spawn")
:proc_lib.spawn(fn -> Process.put(:crumbs, [:a]); raise "proc_lib spawn" end); drain.("proc_lib")
Task.start(fn -> Process.set_label(:tasklbl); raise "task boom" end); drain.("task")
{:ok, g} = GenServer.start(G, %{s: 1}); try do GenServer.call(g, :boom) catch :exit, _ -> :ok end; drain.("genserver")
require Logger; Logger.error("just a log", user_id: 5); drain.("logger.error")
