defmodule Lab05.Upstream do
  @moduledoc "A fake upstream for Req tests."
  import Plug.Conn
  def init(o), do: o
  def call(%{request_path: "/500"} = conn, _), do: send_resp(conn, 500, "upstream down")
  def call(%{request_path: "/slow"} = conn, _), do: (Process.sleep(500); send_resp(conn, 200, "late"))
  def call(conn, _), do: send_resp(conn, 200, "ok")
end
