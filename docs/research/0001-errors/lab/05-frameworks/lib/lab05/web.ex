defmodule Lab05.ErrorJSON do
  def render(template, _assigns),
    do: %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
end

defmodule Lab05.NotFound do
  defexception message: "thing not found", plug_status: 404
end

defmodule Lab05.Controller do
  use Phoenix.Controller, formats: [:json]
  require Logger

  def raise_(_conn, _), do: raise("boom from controller")
  def not_found(_conn, _), do: raise(Lab05.NotFound)
  def throw_(_conn, _), do: throw(:oops)
  def exit_(_conn, _), do: exit(:bye)

  def task(conn, _) do
    Task.start(fn -> raise "boom in task" end)
    Process.sleep(50)
    send_resp(conn, 200, "ok")
  end

  def task_md(conn, _) do
    Logger.metadata(request_id: "r-123")
    Task.start(fn -> raise "boom in task with md" end)
    Process.sleep(50)
    send_resp(conn, 200, "ok")
  end

  def only_one(conn, %{"id" => "1"}), do: send_resp(conn, 200, "one")
  def five_hundred(conn, _), do: send_resp(conn, 500, "silent")
  def echo(conn, params), do: json(conn, params)

  def logged(conn, _) do
    Logger.error("handled but logged", user_id: 42)
    send_resp(conn, 200, "ok")
  end

  def db(conn, _) do
    Lab05.Repo.query!("select * from no_such_table")
    send_resp(conn, 200, "ok")
  end

  def big_params(_conn, %{"password" => _}), do: raise("boom with password param")
end

defmodule Lab05.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
  end

  scope "/", Lab05 do
    pipe_through :api
    get "/raise", Controller, :raise_
    get "/not_found", Controller, :not_found
    get "/throw", Controller, :throw_
    get "/exit", Controller, :exit_
    get "/task", Controller, :task
    get "/task_md", Controller, :task_md
    get "/action/:id", Controller, :only_one
    get "/500", Controller, :five_hundred
    post "/json", Controller, :echo
    get "/logged", Controller, :logged
    get "/db", Controller, :db
    post "/secret", Controller, :big_params
  end

  scope "/", Lab05 do
    pipe_through :browser
    live "/lv", Live
  end
end

defmodule Lab05.Endpoints do
  defmacro plugs do
    quote do
      socket "/socket", Lab05.UserSocket, websocket: true
      socket "/live", Phoenix.LiveView.Socket, websocket: true
      plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
      plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason
      plug Plug.Session, store: :cookie, key: "_lab05", signing_salt: "lab05salt"
      plug Lab05.Router
    end
  end
end

defmodule Lab05.Endpoint do
  use Phoenix.Endpoint, otp_app: :lab05
  require Lab05.Endpoints
  Lab05.Endpoints.plugs()
end

defmodule Lab05.CowboyEndpoint do
  use Phoenix.Endpoint, otp_app: :lab05
  require Lab05.Endpoints
  Lab05.Endpoints.plugs()
end

defmodule Lab05.UserSocket do
  use Phoenix.Socket
  channel "room:*", Lab05.Channel
  def connect(%{"fail" => "raise"}, _socket, _), do: raise("boom in connect")
  def connect(%{"fail" => "deny"}, _socket, _), do: :error
  def connect(_params, socket, _), do: {:ok, socket}
  def id(_), do: nil
end

defmodule Lab05.Channel do
  use Phoenix.Channel
  def join("room:crash", _, _socket), do: raise("boom in join")
  def join("room:" <> _, _, socket), do: {:ok, socket}
  def handle_in("boom", _payload, _socket), do: raise("boom in handle_in")
  def handle_in("error_reply", _payload, socket), do: {:reply, {:error, %{reason: "nope"}}, socket}
  def handle_in("ping", p, socket), do: {:reply, {:ok, p}, socket}
end

defmodule Lab05.Live do
  use Phoenix.LiveView

  def mount(params, _session, socket) do
    if params["crash"] == "mount", do: raise("boom in mount")
    if connected?(socket), do: :persistent_term.put(:lab05_lv, self())
    {:ok, Phoenix.Component.assign(socket, n: 0, secret: "hunter2")}
  end

  def handle_event("boom", _params, _socket), do: raise("boom in handle_event")
  def handle_event("inc", _, socket), do: {:noreply, Phoenix.Component.update(socket, :n, &(&1 + 1))}

  def handle_info(:boom, _socket), do: raise("boom in handle_info")

  def render(assigns) do
    ~H"""
    <div id="n">{@n}</div>
    """
  end
end
