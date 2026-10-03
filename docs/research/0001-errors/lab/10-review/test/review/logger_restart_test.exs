defmodule Review.LoggerRestartTest do
  @moduledoc "Agent 10: run alone (`mix test test/review/logger_restart_test.exs`); it restarts the :logger app."
  use ExUnit.Case, async: false
  @moduletag :logger_restart

  test "10-6: after Application.stop(:logger) + start, a prepended primary filter is gone (and the translator is back first)" do
    :ok = :logger.add_primary_filter(:review_first, {fn _, _ -> :ignore end, nil})
    before = Keyword.keys(:logger.get_primary_config().filters)
    :ok = Application.stop(:logger)
    :ok = Application.start(:logger)
    after_ids = Keyword.keys(:logger.get_primary_config().filters)
    IO.puts("10-6 filters before=#{inspect(before)} after=#{inspect(after_ids)} handlers=#{inspect(:logger.get_handler_ids())}")
    refute :review_first in after_ids
  end
end
