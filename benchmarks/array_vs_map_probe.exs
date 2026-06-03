# Probe: Erlang :array vs Elixir map for the access patterns the table
# workloads exercise. This isolates the data-structure lever from the rest
# of the VM so we can decide whether split storage can plausibly close the
# build/sort gap vs luerl before paying the full refactor cost.

Code.require_file("helpers.exs", __DIR__)

ns = [100, 1000]

build_map = fn n ->
  Enum.reduce(1..n, %{}, fn i, acc -> Map.put(acc, i, i * i) end)
end

build_arr = fn n ->
  Enum.reduce(1..n, :array.new([{:size, n}, {:fixed, false}, {:default, nil}]), fn i, acc ->
    :array.set(i - 1, i * i, acc)
  end)
end

# Pre-build for read/length/sortwrite probes
maps = Map.new(ns, fn n -> {n, build_map.(n)} end)
arrs = Map.new(ns, fn n -> {n, build_arr.(n)} end)

sum_map = fn m, n -> Enum.reduce(1..n, 0, fn i, s -> s + Map.get(m, i) end) end
sum_arr = fn a, n -> Enum.reduce(1..n, 0, fn i, s -> s + :array.get(i - 1, a) end) end

# sort write-back: take sorted values list, write each back under key idx
sortwrite_map = fn n ->
  vals = Enum.to_list(n..1//-1)
  Enum.reduce(Enum.with_index(vals, 1), %{}, fn {v, idx}, acc -> Map.put(acc, idx, v) end)
end

sortwrite_arr = fn n ->
  vals = Enum.to_list(n..1//-1)
  base = :array.new([{:size, n}, {:fixed, false}, {:default, nil}])
  Enum.reduce(Enum.with_index(vals, 1), base, fn {v, idx}, acc -> :array.set(idx - 1, v, acc) end)
end

# sequence_length: map probes 1..n+1; array is just :array.size
seqlen_map = fn m ->
  Stream.iterate(1, &(&1 + 1)) |> Enum.find(fn i -> not Map.has_key?(m, i) end) |> Kernel.-(1)
end

for n <- ns do
  Bench.banner("DS probe n=#{n}")

  Benchee.run(
    %{
      "build map" => fn -> build_map.(n) end,
      "build array" => fn -> build_arr.(n) end
    },
    Bench.opts()
  )

  Benchee.run(
    %{
      "sum map (read)" => fn -> sum_map.(maps[n], n) end,
      "sum array (read)" => fn -> sum_arr.(arrs[n], n) end
    },
    Bench.opts()
  )

  Benchee.run(
    %{
      "sortwrite map" => fn -> sortwrite_map.(n) end,
      "sortwrite array" => fn -> sortwrite_arr.(n) end
    },
    Bench.opts()
  )

  Benchee.run(
    %{
      "seqlen map (probe)" => fn -> seqlen_map.(maps[n]) end,
      "seqlen array (size)" => fn -> :array.size(arrs[n]) end
    },
    Bench.opts()
  )
end
