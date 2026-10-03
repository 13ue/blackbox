defmodule Blackbox.ScrubTest do
  use ExUnit.Case, async: true
  alias Blackbox.Scrub

  @f "[Filtered]"

  test "text: key=value, key: value, key: \"value\", \"key\" => \"value\", any case" do
    assert Scrub.text("GET /x?key=ck_live_1&page=2") == "GET /x?key=#{@f}&page=2"
    assert Scrub.text("password: hunter2 next") == "password: #{@f} next"
    assert Scrub.text(~s(%{api_key: "abc", n: 1})) == ~s(%{api_key: #{@f}, n: 1})
    assert Scrub.text(~s(%{"Authorization" => "Bearer x"})) == ~s(%{"Authorization" => #{@f}})
    assert Scrub.text("TOKEN=abc") == "TOKEN=#{@f}"
    assert Scrub.text("token = abc") == "token = #{@f}"
    assert Scrub.text("key :missing not found") == "key :missing not found"
    assert Scrub.text("board_key=k1") == "board_key=#{@f}"
  end

  test "text: the host's patterns, group 1 or the whole match" do
    assert Scrub.text("GET /b/my-board/tabs") == "GET /b/#{@f}/tabs"
    assert Scrub.text("nothing here") == "nothing here"
  end

  test "terms: values under secret keys, in maps, keyword lists, structs and nesting" do
    t = %{
      user: %{name: "a", password: "p"},
      opts: [token: "t", page: 1],
      list: [{"Cookie", "c"}],
      uri: URI.parse("http://x/b/b1?key=k")
    }

    s = Scrub.term(t)
    assert s.user == %{name: "a", password: @f}
    assert s.opts == [token: @f, page: 1]
    assert s.list == [{"Cookie", @f}]
    assert %URI{path: "/b/" <> @f, query: "key=" <> @f} = s.uri
  end

  test "terms: a call inside an exit reason keeps only its tag" do
    reason = {:timeout, {GenServer, :call, [self(), {:apply, ["op with text"], 3}, 5000]}}
    assert {:timeout, {GenServer, :call, [_, {:apply, :...}, 5000]}} = Scrub.term(reason)
  end

  test "exceptions whose fields carry values are kept as shapes" do
    key =
      try do
        Map.fetch!(%{name: "my-private-space", n: 1}, :missing)
      rescue
        e -> e
      end

    msg = Exception.message(Scrub.term(key))
    # Elixir 1.20 breaks the line before the map; 1.18 does not.
    assert msg =~ "key :missing not found in:"
    assert msg =~ ~s(name: "[Filtered]") and msg =~ ~s(n: "[Filtered]")

    assert Scrub.text(Exception.message(Scrub.term(key))) == Exception.message(Scrub.term(key))

    by_string =
      try do
        Map.fetch!(%{}, "ck_live_SECRET")
      rescue
        e -> e
      end

    refute Exception.message(Scrub.term(by_string)) =~ "ck_live"

    match =
      try do
        {:ok, _} = Function.identity({:error, "private"})
      rescue
        e -> e
      end

    # The wording differs between Elixir 1.18 and 1.20; the shape does not.
    assert Exception.message(Scrub.term(match)) =~ "{:error, :...}"
    refute Exception.message(Scrub.term(match)) =~ "private"

    clause =
      try do
        Blackbox.Fixtures.Sites.only_ok(Function.identity({:error, "private"}))
      rescue
        e -> e
      end

    assert %FunctionClauseError{args: nil} = Scrub.term(clause)
  end

  test "deep and improper terms do not crash" do
    deep = Enum.reduce(1..100, :x, &{&1, &2})
    assert Scrub.term(deep)
    assert Scrub.term([1 | :improper]) == [1 | :improper]
  end

  test "a stack frame nested in a term keeps its arity, not its arguments" do
    reason =
      {{:function_clause, [{M, :handle_call, [{:unknown, "private"}, :from, %{}], [line: 1]}]},
       {GenServer, :call, [self(), :x, 5000]}}

    assert {{:function_clause, [{M, :handle_call, 3, [line: 1]}]}, _} = Scrub.term(reason)
  end

  test "the :sys log keeps message tags and scrubbed states" do
    log = [
      {:in, {:"$gen_call", {self(), make_ref()}, {:say, :from, "private"}}},
      {:in, {:"$gen_cast", {:apply, "ops"}}},
      {:noreply, %{token: "t", n: 1}},
      {:out, {:reply, "private"}, self(), %{}}
    ]

    assert [
             {:in, :call, {:say, :...}},
             {:in, :cast, {:apply, :...}},
             {:noreply, %{token: @f, n: 1}},
             {:out, {:reply, :...}, _}
           ] =
             Scrub.sys_log(log)
  end
end
