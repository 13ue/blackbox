defmodule Lab01.BanditTest do
  # Phoenix 1.8's default server is Bandit. Claims from the source read of
  # sentry 13.5.1 + bandit 1.12. Ports 4331-4334 only, started under ExUnit.
  use Lab01.Case, async: false

  defmodule NotFound do
    defexception message: "no such board", plug_status: 404
  end

  defmodule Router do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON
    plug Sentry.PlugContext
    plug :dispatch
    get "/boom", do: raise("controller boom #{conn.query_string}")
    get "/nf", do: raise(NotFound)
  end

  defmodule CapturedRouter do
    use Plug.Router
    use Sentry.PlugCapture
    plug :match
    plug Sentry.PlugContext
    plug :dispatch
    get "/boom", do: raise("controller boom #{conn.query_string}")
    get "/nf", do: raise(NotFound)
  end

  defp serve(plug, port) do
    start_supervised!({Bandit, plug: plug, port: port, ip: :loopback, startup_log: false})
  end

  defp get!(port, path) do
    ExUnit.CaptureLog.capture_log(fn ->
      send(self(), {:status, Req.get!("http://127.0.0.1:#{port}#{path}", retry: false).status})
    end)

    assert_received {:status, status}
    status
  end

  test "01-3: Bandit, no PlugCapture (as the guide says), handler attached by hand with defaults -> controller exception is LOST" do
    serve(Router, 4331)
    attach()
    assert get!(4331, "/boom?a=1") == 500
    assert captured() == []
  end

  test "01-4: same, but capture_excluded_domains: [:cowboy] (the auto-attach default) -> one event with request context" do
    serve(Router, 4332)
    attach(%{capture_excluded_domains: [:cowboy]})
    assert get!(4332, "/boom?a=2") == 500
    assert [e] = captured()
    assert title(e) == "RuntimeError: controller boom a=2"
    assert e.request.method == "GET"
    # first run RED on this line only: Elixir Logger prepends :elixir
    assert e.extra.domain == [:elixir, :bandit]
  end

  test "01-5: Bandit + PlugCapture + handler not excluding :bandit -> the same failure is sent twice (dedupe misses it)" do
    serve(CapturedRouter, 4333)
    attach(%{capture_excluded_domains: [:cowboy]})
    assert get!(4333, "/boom?a=3") == 500
    assert [_, _] = captured()
    assert [a, b] = sent()
    assert title(a) == title(b)
    assert Sentry.Event.hash(a) != Sentry.Event.hash(b)
  end

  test "01-5b: a 404 exception (plug_status 404, not in the hard-coded list) is reported by PlugCapture as an error" do
    serve(CapturedRouter, 4334)
    assert get!(4334, "/nf") == 404
    assert [e] = sent()
    assert title(e) =~ "no such board"
  end
end
