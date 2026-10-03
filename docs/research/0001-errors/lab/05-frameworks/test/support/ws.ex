defmodule Lab05.WS do
  @moduledoc "Minimal WebSocket client over :gen_tcp, enough for Phoenix V2 JSON frames."
  import Bitwise

  def connect(port, path) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    :ok = :gen_tcp.send(s, "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    {:ok, resp} = :gen_tcp.recv(s, 0, 2000)
    [status_line | _] = String.split(resp, "\r\n")
    {s, status_line}
  end

  def push(s, list) do
    payload = Jason.encode!(list)
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)
    hdr = if len < 126, do: <<0x81, 1::1, len::7>>, else: <<0x81, 1::1, 126::7, len::16>>
    :ok = :gen_tcp.send(s, [hdr, mask, xor(payload, mask)])
  end

  def recv(s, timeout \\ 1000) do
    case :gen_tcp.recv(s, 2, timeout) do
      {:ok, <<_fin_op, 0::1, len::7>>} ->
        len = case len do
          126 -> {:ok, <<l::16>>} = :gen_tcp.recv(s, 2, timeout); l
          127 -> {:ok, <<l::64>>} = :gen_tcp.recv(s, 8, timeout); l
          l -> l
        end
        {:ok, data} = if len == 0, do: {:ok, ""}, else: :gen_tcp.recv(s, len, timeout)
        case Jason.decode(data) do
          {:ok, v} -> {:ok, v}
          _ -> {:ok, {:raw, data}}
        end
      other -> other
    end
  end

  def recv_all(s, acc \\ []) do
    case recv(s, 300) do
      {:ok, f} -> recv_all(s, [f | acc])
      _ -> Enum.reverse(acc)
    end
  end

  defp xor(payload, mask) do
    m = :binary.bin_to_list(mask)
    payload |> :binary.bin_to_list() |> Enum.with_index() |> Enum.map(fn {b, i} -> bxor(b, Enum.at(m, rem(i, 4))) end) |> :binary.list_to_bin()
  end
end
