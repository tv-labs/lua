defmodule Lua.VM.Bootstrap do
  @moduledoc """
  Memoizes boot-time VM templates in `:persistent_term`.

  Building a VM means installing the whole standard library — allocating a
  dozen tables and capturing a hundred-odd native-function closures — and the
  result is a pure, deterministic value: two builds from the same code produce
  byte-identical terms. Nothing in it is per-instance (no refs, no pids, no
  timestamps), and every downstream mutation is copy-on-write, so a single
  template can seed unlimited independent VMs.

  `fetch/2` builds a template on first use and stores it under `key`. Later
  calls return the stored term for the cost of one `:persistent_term.get/2`.
  The key is written exactly once per node: a `put` on an existing key forces a
  global scan of every process, so the stored term is never refreshed except by
  the staleness path below.

  ## Staleness

  A template holds closures pointing into the modules that built it. Reload
  those modules twice and the old code is purged, turning every captured
  closure into a `badfun`. That only happens while iterating in a shell, so the
  guard is priced for it: at build time, in `:interactive` mode, every module
  reachable through a captured fun is fingerprinted by its `module_info(:md5)`,
  and a `fetch/2` hit re-checks those hashes before handing the term back. A
  mismatch rebuilds. Under `:embedded` mode (releases) code never reloads, so no
  fingerprint is taken and a hit is the bare `get`.
  """

  @typep fingerprint :: :static | [{module(), binary()}]

  @doc """
  Returns the memoized template for `key`, building it with `builder` on a miss.

  `builder` must be pure: it is invoked once per node (plus once more after a
  module reload in `:interactive` mode) and every caller shares the result.
  """
  @spec fetch(term(), (-> term())) :: term()
  def fetch(key, builder) when is_function(builder, 0) do
    case :persistent_term.get(key, nil) do
      nil ->
        build_and_store(key, builder)

      {fingerprint, term} ->
        if current?(fingerprint), do: term, else: build_and_store(key, builder)
    end
  end

  defp build_and_store(key, builder) do
    term = builder.()
    :persistent_term.put(key, {fingerprint(term), term})
    term
  end

  defp current?(:static), do: true

  defp current?(fingerprint) do
    Enum.all?(fingerprint, fn {module, md5} -> module.module_info(:md5) === md5 end)
  end

  @spec fingerprint(term()) :: fingerprint()
  defp fingerprint(term) do
    case :code.get_mode() do
      :interactive ->
        term
        |> fun_modules()
        |> Enum.uniq()
        |> Enum.map(fn module -> {module, module.module_info(:md5)} end)

      _embedded ->
        :static
    end
  end

  # Every module reachable through a closure stored anywhere in the term. Runs
  # once per build, so a plain structural walk is fine.
  defp fun_modules(fun) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    [module]
  end

  defp fun_modules(list) when is_list(list), do: Enum.flat_map(list, &fun_modules/1)

  # `:maps.to_list/1` rather than `Enum`: structs are maps here too, and they
  # are not enumerable.
  defp fun_modules(map) when is_map(map), do: map |> :maps.to_list() |> fun_modules()

  defp fun_modules(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> fun_modules()
  end

  defp fun_modules(_other), do: []
end
