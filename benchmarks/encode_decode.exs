# benchmarks/encode_decode.exs
#
# Isolated micro-benchmarks that decompose the Lua.encode!/2 + Lua.decode!/2
# round-trip regression. On a nested map the native VM measured ~6x slower than
# luerl 0.4.0 (18us -> 108us); every other scenario stayed within ~2x. This
# script exists to attribute that 6x to a specific direction, container shape,
# and size so the root cause is obvious rather than guessed.
#
# ---------------------------------------------------------------------------
# How to read the output
# ---------------------------------------------------------------------------
# Each row reports total time for one operation and, crucially, the
# per-element cost (per_elem_ns = total / element_count):
#
#   * per_elem_ns roughly CONSTANT as N grows  -> linear cost, nothing to see
#   * per_elem_ns GROWS as N grows             -> super-linear (algorithmic)
#     cost. That is the smoking gun -- e.g. O(n^2) list building, a decode that
#     builds-then-reverses, or repeated rehashing/lookups per element.
#
# Comparing the `encode` rows to the `decode` rows attributes the round-trip
# cost to a direction. Comparing shapes at equal N attributes it to a
# container kind (list vs string-keyed map vs integer-keyed map vs records vs
# depth). The nested_chain sweep isolates recursion/traversal depth from
# fan-out.
#
# ---------------------------------------------------------------------------
# How to run
# ---------------------------------------------------------------------------
# Inside any project that has `lua` as a dependency -- including the tv-labs/lua
# repo itself, where `mix run` benches your working tree directly:
#
#     mix run benchmarks/encode_decode.exs
#
# To compare engines, run it once from a project pinned to lua 0.4.0 (luerl)
# and once from one pinned to the native VM, then diff the per_elem_ns columns.
# The script prints the loaded `lua` version in its header.

defmodule EncDecBench do
  # Sizes chosen to span ~3 orders of magnitude so a super-linear curve is
  # unmistakable. Trim the large end if a shape gets too slow to be practical.
  @sizes [8, 64, 512, 4096]
  @depths [4, 16, 64, 256]

  # Minimum wall-clock per timed batch; reps auto-scale to reach it so tiny
  # ops aren't swamped by :timer.tc resolution. Median of @samples batches.
  @min_batch_us 30_000
  @samples 5

  # ---- builders: each takes a size and returns a plain Elixir term ----
  def int_list(n), do: Enum.to_list(1..n)
  def float_list(n), do: Enum.map(1..n, &(&1 * 1.5))
  def bool_list(n), do: Enum.map(1..n, fn i -> rem(i, 2) == 0 end)
  def short_string_list(n), do: Enum.map(1..n, &"s#{&1}")

  def long_string_list(n),
    do: Enum.map(1..n, fn i -> String.duplicate("x", 200) <> Integer.to_string(i) end)

  def string_map(n), do: Map.new(1..n, fn i -> {"key_#{i}", i} end)
  def int_map(n), do: Map.new(1..n, fn i -> {i, i} end)

  def record_list(n) do
    Enum.map(1..n, fn i ->
      %{"id" => i, "name" => "contact #{i}", "active" => rem(i, 2) == 0, "score" => i * 1.5}
    end)
  end

  def nested_chain(0), do: %{"leaf" => true}
  def nested_chain(d), do: %{"depth" => d, "child" => nested_chain(d - 1)}

  # The exact composite from the PR benchmark, to anchor the 18us/108us number.
  def original_nested do
    %{
      "name" => "benchmark contact",
      "fields" => Map.new(1..20, fn i -> {"field_#{i}", "value #{i}"} end),
      "tags" => Enum.map(1..50, &"tag-#{&1}"),
      "meta" => %{"a" => 1, "b" => true, "c" => 3.14}
    }
  end

  defp elem_count(term) when is_list(term), do: max(length(term), 1)
  defp elem_count(term) when is_map(term), do: max(map_size(term), 1)
  defp elem_count(_), do: 1

  # ---- timing harness ----
  defp time_batch(fun, reps) do
    {us, _} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> fun.() end) end)
    us
  end

  defp calibrate(fun, reps) do
    cond do
      reps >= 5_000_000 -> reps
      time_batch(fun, reps) >= @min_batch_us -> reps
      true -> calibrate(fun, reps * 4)
    end
  end

  # Microseconds per single call (median of @samples batches).
  defp measure(fun) do
    fun.()
    reps = calibrate(fun, 1)
    samples = for _ <- 1..@samples, do: time_batch(fun, reps) / reps
    Enum.at(Enum.sort(samples), div(@samples, 2))
  end

  # ---- run ----
  def run do
    materialize? =
      Code.ensure_loaded?(Lua.Table) and function_exported?(Lua.Table, :deep_cast, 1)

    IO.puts("lua #{Application.spec(:lua, :vsn)} — encode!/decode! decomposition")
    IO.puts("(decode+deep_cast column: #{if materialize?, do: "enabled", else: "N/A on this engine"})")
    IO.puts(String.duplicate("=", 82))
    header()

    builders = [
      {"int_list", &int_list/1},
      {"float_list", &float_list/1},
      {"bool_list", &bool_list/1},
      {"short_string_list", &short_string_list/1},
      {"long_string_list", &long_string_list/1},
      {"string_map", &string_map/1},
      {"int_map", &int_map/1},
      {"record_list", &record_list/1}
    ]

    for {name, builder} <- builders do
      for n <- @sizes, do: bench_shape(name, builder.(n), n, materialize?)
      IO.puts(String.duplicate("-", 82))
    end

    IO.puts("nested chain (depth sweep) — isolates recursion/traversal from fan-out")
    header()
    for d <- @depths, do: bench_shape("nested_chain", nested_chain(d), d, materialize?)

    IO.puts(String.duplicate("=", 82))
    IO.puts("composite anchor — the PR's `original_nested` (matches the 18us/108us figure)")
    header()
    bench_shape("original_nested", original_nested(), 75, materialize?)
  end

  # Encodes from a FIXED base state (built once) so we time encoding, not
  # Lua.new() (~80-107us, which would swamp small-N encode). The returned state
  # is discarded, so the base never grows across reps.
  defp bench_shape(name, term, n, materialize?) do
    base = Lua.new()
    count = elem_count(term)

    enc_us = measure(fn -> Lua.encode!(base, term) end)
    row("encode", name, n, enc_us, count)

    {encoded, state} = Lua.encode!(base, term)
    dec_us = measure(fn -> Lua.decode!(state, encoded) end)
    row("decode", name, n, dec_us, count)

    if materialize? do
      mat_us = measure(fn -> Lua.Table.deep_cast(Lua.decode!(state, encoded)) end)
      row("dec+cast", name, n, mat_us, count)
    end
  end

  defp header do
    IO.puts(
      pad("op", 9) <>
        pad("shape", 20) <>
        lpad("N", 7) <>
        lpad("total_us", 13) <>
        lpad("per_elem_ns", 14)
    )
  end

  defp row(op, shape, n, total_us, count) do
    IO.puts(
      pad(op, 9) <>
        pad(shape, 20) <>
        lpad(Integer.to_string(n), 7) <>
        lpad(:erlang.float_to_binary(total_us, decimals: 2), 13) <>
        lpad(:erlang.float_to_binary(total_us * 1000 / count, decimals: 1), 14)
    )
  end

  defp pad(s, w), do: String.pad_trailing(s, w)
  defp lpad(s, w), do: String.pad_leading(s, w)
end

EncDecBench.run()
