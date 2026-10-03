defmodule Lab05.PlainRouter do
  use Plug.Router
  use Plug.ErrorHandler

  plug :match
  plug :dispatch

  get "/raise/:id" do
    _ = conn
    raise "plain boom #{id}"
  end

  get "/ok" do
    send_resp(conn, 200, "ok")
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason}) do
    send(:persistent_term.get(:lab05_test_pid), {:handle_errors, self(), kind, reason})
    send_resp(conn, conn.status, "handled")
  end
end
