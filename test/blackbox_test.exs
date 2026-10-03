defmodule BlackboxTest do
  use ExUnit.Case
  doctest Blackbox

  test "greets the world" do
    assert Blackbox.hello() == :world
  end
end
