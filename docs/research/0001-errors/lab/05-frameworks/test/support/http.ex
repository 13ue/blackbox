defmodule Lab05.HTTP do
  def req(port, method, path, body \\ nil, ctype \\ ~c"application/json") do
    url = ~c"http://127.0.0.1:#{port}#{path}"
    headers = [{~c"accept", ~c"application/json"}]
    r = if body, do: {url, headers, ctype, body}, else: {url, headers}
    {:ok, {{_, status, _}, _h, resp}} = :httpc.request(method, r, [], [])
    {status, to_string(resp)}
  end
end
