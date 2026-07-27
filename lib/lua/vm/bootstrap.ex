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
  There is no mutual exclusion: callers racing a cold start each build and
  `put`, and every `put` over a live key forces a global scan of every
  process. Builders are pure, so the racing puts all store equal terms — the
  race costs redundant work on first use, never an inconsistent result — and
  once warm the key is effectively write-once, refreshed only by the
  staleness path below.

  ## Staleness

  A template holds closures pointing into the modules that built it. Reload
  those modules twice and the old code is purged, turning every captured
  closure into a `badfun`. That only happens while iterating in a shell, so the
  guard is priced for it: at build time, in `:interactive` mode, every module
  reachable through a captured fun — plus the template-shaping modules whose
  struct layouts and defaults are baked into the term without leaving a
  closure in it — is fingerprinted by its `module_info(:md5)`, and a `fetch/2`
  hit re-checks those hashes before handing the term back. A mismatch (or a
  fingerprinted module that can no longer be loaded) rebuilds.

  Under `:embedded` mode (releases) code never reloads on its own, so no
  fingerprint is taken and a hit is the bare `get`. A host that loads new
  Lua-implementation code anyway — `:code.load_file/1`, a remote-console
  recompile, a hot upgrade — must call `reset/0` afterwards, or `fetch/2`
  keeps serving templates built against the replaced code.
  """

  @typep fingerprint :: :static | [{module(), binary() | nil}]

  # Modules whose code shapes a built template without necessarily leaving a
  # captured closure inside it: struct layouts, table splitting, and default
  # limits are baked into the stored term at build time, so reloading any of
  # these must invalidate the template even though no fun in it points there.
  @template_modules [__MODULE__, Lua, Lua.VM.Limits, Lua.VM.State, Lua.VM.Stdlib, Lua.VM.Table]

  # Every key `fetch/2` may be called with, and therefore everything `reset/0`
  # has to erase. Fixed at compile time on purpose: the store stays a known,
  # bounded size, and `reset/0` needs no bookkeeping that a concurrent cold
  # start could lose.
  @memoized_keys [{Lua, :default_lua}, {Lua, :base_state}]

  # Earlier builds tracked the keys here at runtime. Erased by `reset/0` so a
  # release upgraded from one of those builds does not keep the entry forever.
  @obsolete_registry {__MODULE__, :keys}

  @doc """
  Returns the memoized template for `key`, building it with `builder` on a miss.

  `key` must be one of the compile-time literals in `memoized_keys/0`. That is
  what bounds the store: `:persistent_term` has no eviction, so a key derived
  from user input would grow it without limit, and `reset/0` would not know to
  erase it.

  `builder` must be pure: it is invoked on a cold start (possibly more than
  once under concurrent first use, see the moduledoc) and again after a module
  reload in `:interactive` mode; every caller shares the stored result.
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

  @doc """
  The keys `fetch/2` accepts, and the exact set `reset/0` erases.
  """
  @spec memoized_keys() :: [term()]
  def memoized_keys, do: @memoized_keys

  @doc """
  Erases every memoized template, so the next `fetch/2` of each key rebuilds.

  Required after explicitly loading new Lua-implementation code in `:embedded`
  mode (releases), where no staleness fingerprint exists — see the moduledoc.
  Safe to call at any time in any mode; concurrent `fetch/2` callers simply
  rebuild.
  """
  @spec reset() :: :ok
  def reset do
    Enum.each([@obsolete_registry | @memoized_keys], &:persistent_term.erase/1)
    :ok
  end

  defp build_and_store(key, builder) do
    term = builder.()
    :persistent_term.put(key, {fingerprint(term), term})
    term
  end

  defp current?(:static), do: true

  defp current?(fingerprint) do
    Enum.all?(fingerprint, fn {module, md5} -> loaded_md5(module) === md5 end)
  end

  # A fingerprinted module that has since been deleted has no md5 to compare;
  # returning nil makes the comparison fail, so the caller rebuilds instead of
  # raising `UndefinedFunctionError` mid-fetch.
  defp loaded_md5(module) do
    case :code.ensure_loaded(module) do
      {:module, ^module} -> module.module_info(:md5)
      {:error, _reason} -> nil
    end
  end

  @spec fingerprint(term()) :: fingerprint()
  defp fingerprint(term) do
    case :code.get_mode() do
      :interactive ->
        term
        |> fun_modules()
        |> Enum.concat(@template_modules)
        |> Enum.uniq()
        |> Enum.map(fn module -> {module, loaded_md5(module)} end)

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
