defmodule Lua.VM.Stdlib.Os do
  @moduledoc """
  Lua 5.3 `os` standard library (sandbox-safe subset).

  Provides time and date facilities plus a handful of environment
  helpers. Functions that would touch the filesystem or spawn
  subprocesses are intentionally absent or stubbed, since the VM runs in
  an embedded sandbox.

  ## Functions

  - `os.time([table])` - Epoch seconds, optionally from a date table.
  - `os.time_ms()` - Current epoch in milliseconds (extension; not in PUC-Lua).
  - `os.time_us()` - Current epoch in microseconds (extension; not in PUC-Lua).
  - `os.clock()` - Approximate CPU time used, in seconds.
  - `os.difftime(t2, t1)` - Difference in seconds between two times.
  - `os.date([format [, time]])` - Formats a time as a string or table.
  - `os.getenv(name)` - Value of an environment variable, or nil.
  - `os.setlocale([locale [, category]])` - Only the "C" locale is available;
    returns "C" for a query or a "C"/"" request and nil for any other locale.
  - `os.tmpname()` - A name usable for a temporary file.
  - `os.exit([code [, close]])` - Raises to unwind; sandbox cannot exit.
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Sandbox
  alias Lua.VM.Stdlib.Util

  @impl true
  def lib_name, do: "os"

  @impl true
  def install(%{sandboxed?: sandboxed?} = state) do
    # Seed the monotonic origin at install time so os.clock() measures from a
    # stable startup point rather than from whenever it is first called.
    boot_offset()

    {tref, state} = State.alloc_table(state, os_table(sandboxed?))
    State.set_global(state, "os", tref)
  end

  # Mode-independent functions are installed identically in both modes; the
  # filesystem/env/exec functions are swapped for their virtual or host
  # implementation at install time, so there is no per-call mode branch.
  defp os_table(sandboxed?) do
    common = %{
      "clock" => {:native_func, &os_clock/2},
      "date" => {:native_func, &os_date/2},
      "difftime" => {:native_func, &os_difftime/2},
      "exit" => {:native_func, &os_exit/2},
      "setlocale" => {:native_func, &os_setlocale/2},
      "time" => {:native_func, &os_time/2},
      "time_ms" => {:native_func, &os_time_ms/2},
      "time_us" => {:native_func, &os_time_us/2}
    }

    Map.merge(common, mode_table(sandboxed?))
  end

  defp mode_table(true) do
    %{
      "getenv" => {:native_func, &os_getenv_virtual/2},
      "tmpname" => {:native_func, &os_tmpname_virtual/2},
      "remove" => {:native_func, &os_remove_virtual/2},
      "rename" => {:native_func, &os_rename_virtual/2},
      "execute" => Sandbox.stub([:os, :execute])
    }
  end

  defp mode_table(false) do
    %{
      "getenv" => {:native_func, &os_getenv_host/2},
      "tmpname" => {:native_func, &os_tmpname_host/2},
      "remove" => {:native_func, &os_remove_host/2},
      "rename" => {:native_func, &os_rename_host/2},
      "execute" => {:native_func, &os_execute_host/2}
    }
  end

  # os.clock() — approximate CPU/elapsed time used, in seconds. Reads the
  # boot offset before the current time so the elapsed value is never
  # negative on the first call (when the offset is seeded lazily).
  defp os_clock(_args, state) do
    offset = boot_offset()
    elapsed_ns = :erlang.monotonic_time(:nanosecond) - offset
    seconds = max(0, elapsed_ns) / 1_000_000_000
    {[seconds], state}
  end

  # os.difftime(t2, t1) — t2 - t1 as a float number of seconds.
  defp os_difftime([t2, t1 | _], state) when is_number(t2) and is_number(t1) do
    {[(t2 - t1) / 1], state}
  end

  defp os_difftime([t2 | _], state) when is_number(t2) do
    {[t2 / 1], state}
  end

  defp os_difftime([t2 | _], _state) do
    raise ArgumentError.type_error("os.difftime", 1, "number", Util.typeof(t2))
  end

  defp os_difftime([], _state) do
    raise ArgumentError.value_expected("os.difftime", 1)
  end

  # os.time([table]) — current epoch seconds, or seconds for the given
  # date table (fields: year, month, day, hour, min, sec, isdst).
  defp os_time([], state) do
    {[System.os_time(:second)], state}
  end

  defp os_time([nil | _], state) do
    {[System.os_time(:second)], state}
  end

  defp os_time([{:tref, _} = tref | _], state) do
    data = State.get_table(state, tref).data

    year = required_field(data, "year", "os.time")
    month = required_field(data, "month", "os.time")
    day = required_field(data, "day", "os.time")
    hour = optional_field(data, "hour", 12)
    min = optional_field(data, "min", 0)
    sec = optional_field(data, "sec", 0)

    seconds =
      naive_to_epoch(%{
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: min,
        second: sec
      })

    {[seconds], state}
  end

  defp os_time([arg | _], _state) do
    raise ArgumentError.type_error("os.time", 1, "table", Util.typeof(arg))
  end

  # os.time_ms() — current epoch in milliseconds. Non-standard extension (not
  # present in PUC-Lua); use os.time() for portable, whole-second time.
  defp os_time_ms(_args, state) do
    {[System.os_time(:millisecond)], state}
  end

  # os.time_us() — current epoch in microseconds. Non-standard extension (not
  # present in PUC-Lua); use os.time() for portable, whole-second time.
  defp os_time_us(_args, state) do
    {[System.os_time(:microsecond)], state}
  end

  # os.date([format [, time]]) — formats a time.
  defp os_date([], state), do: os_date(["%c"], state)
  defp os_date([nil | rest], state), do: os_date(["%c" | rest], state)

  defp os_date([format | rest], state) when is_binary(format) do
    {format, utc?} = strip_utc_flag(format)

    time =
      case rest do
        [t | _] when is_number(t) -> trunc(t)
        _ -> System.os_time(:second)
      end

    dt = to_datetime(time, utc?)

    case format do
      "*t" -> date_table(dt, state)
      _ -> {[strftime(format, dt)], state}
    end
  end

  defp os_date([format | _], _state) do
    raise ArgumentError.type_error("os.date", 1, "string", Util.typeof(format))
  end

  # os.getenv(name) — value of an environment variable, or nil.
  #
  # Sandboxed: reads only the env injected via `Lua.new(env: ...)`, never the
  # host environment. Host: reads the real process environment.
  defp os_getenv_virtual([name | _], %{env: env} = state) when is_binary(name) do
    {[Map.get(env, name)], state}
  end

  defp os_getenv_virtual(args, _state), do: os_getenv_bad_arg(args)

  defp os_getenv_host([name | _], state) when is_binary(name) do
    {[System.get_env(name)], state}
  end

  defp os_getenv_host(args, _state), do: os_getenv_bad_arg(args)

  defp os_getenv_bad_arg([name | _]) do
    raise ArgumentError.type_error("os.getenv", 1, "string", Util.typeof(name))
  end

  defp os_getenv_bad_arg([]) do
    raise ArgumentError.value_expected("os.getenv", 1)
  end

  # os.setlocale([locale [, category]]) — the sandbox only carries the default
  # "C" locale. A query (nil locale) and a request for "C" or "" all report
  # "C"; any other named locale is unavailable, so return nil like a C runtime
  # whose locale data is missing.
  defp os_setlocale([locale | _], state) when locale not in [nil, "C", ""] do
    {[nil], state}
  end

  defp os_setlocale(_args, state), do: {["C"], state}

  # os.tmpname() — a name usable for a temporary file.
  #
  # Sandboxed: a virtual path under `/tmp`, never touching the host. Host:
  # a name under the real temp directory.
  defp os_tmpname_virtual(_args, state) do
    {["/tmp/lua_#{:erlang.unique_integer([:positive])}"], state}
  end

  defp os_tmpname_host(_args, state) do
    name = Path.join(System.tmp_dir() || "/tmp", "lua_#{:erlang.unique_integer([:positive])}")
    {[name], state}
  end

  # os.remove(filename) / os.rename(from, to) — Lua 5.3 returns `true` on
  # success or `(nil, message, errno)` on failure. Sandboxed variants operate
  # on the VFS; host variants touch the real disk.
  defp os_remove_virtual([name | _], state) when is_binary(name) do
    case State.vfs_rm(state, name) do
      {:ok, state} -> {[true], state}
      {:error, reason, state} -> {fs_failure(name, reason), state}
    end
  end

  defp os_remove_virtual(args, _state), do: os_remove_bad_arg(args)

  defp os_remove_host([name | _], state) when is_binary(name) do
    case File.rm(name) do
      :ok -> {[true], state}
      {:error, reason} -> {fs_failure(name, reason), state}
    end
  end

  defp os_remove_host(args, _state), do: os_remove_bad_arg(args)

  defp os_remove_bad_arg([name | _]), do: raise(ArgumentError.type_error("os.remove", 1, "string", Util.typeof(name)))

  defp os_remove_bad_arg([]), do: raise(ArgumentError.value_expected("os.remove", 1))

  defp os_rename_virtual([from, to | _], state) when is_binary(from) and is_binary(to) do
    with {:ok, contents} <- State.vfs_read(state, from),
         {:ok, state} <- State.vfs_write(state, to, contents),
         {:ok, state} <- State.vfs_rm(state, from) do
      {[true], state}
    else
      {:error, reason} -> {fs_failure(from, reason), state}
      {:error, reason, state} -> {fs_failure(from, reason), state}
    end
  end

  defp os_rename_virtual(args, _state), do: os_rename_bad_arg(args)

  defp os_rename_host([from, to | _], state) when is_binary(from) and is_binary(to) do
    case File.rename(from, to) do
      :ok -> {[true], state}
      {:error, reason} -> {fs_failure(from, reason), state}
    end
  end

  defp os_rename_host(args, _state), do: os_rename_bad_arg(args)

  defp os_rename_bad_arg([from | _]) when not is_binary(from),
    do: raise(ArgumentError.type_error("os.rename", 1, "string", Util.typeof(from)))

  defp os_rename_bad_arg([_from | rest]) do
    raise ArgumentError.type_error("os.rename", 2, "string", Util.typeof(List.first(rest)))
  end

  defp os_rename_bad_arg([]), do: raise(ArgumentError.value_expected("os.rename", 1))

  # os.execute([command]) — host only. With no command, reports shell
  # availability (true). With a command, runs it via the system shell and
  # returns `(true|nil, "exit", code)` per Lua 5.3.
  defp os_execute_host([], state), do: {[true], state}

  defp os_execute_host([command | _], state) when is_binary(command) do
    {_output, status} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
    success = if status == 0, do: true
    {[success, "exit", status], state}
  end

  defp os_execute_host([command | _], _state) do
    raise ArgumentError.type_error("os.execute", 1, "string", Util.typeof(command))
  end

  # Map an errno atom to Lua's `(nil, "<path>: <reason>", errno)` failure shape.
  defp fs_failure(path, reason) do
    [nil, "#{path}: #{:file.format_error(reason)}", errno(reason)]
  end

  defp errno(:enoent), do: 2
  defp errno(:eisdir), do: 21
  defp errno(:einval), do: 22
  defp errno(:eacces), do: 13
  defp errno(:eexist), do: 17
  defp errno(_), do: 1

  # os.exit([code [, close]]) — the sandbox cannot terminate the host, so
  # raise to unwind the current evaluation.
  defp os_exit(_args, _state) do
    raise RuntimeError, value: "os.exit is not supported in embedded mode"
  end

  ## Helpers

  defp required_field(data, key, fn_name) do
    case Map.get(data, key) do
      n when is_number(n) ->
        trunc(n)

      _ ->
        raise RuntimeError, value: "field '#{key}' missing in date table for '#{fn_name}'"
    end
  end

  defp optional_field(data, key, default) do
    case Map.get(data, key) do
      n when is_number(n) -> trunc(n)
      _ -> default
    end
  end

  defp naive_to_epoch(%{year: y, month: mo, day: d, hour: h, minute: mi, second: s}) do
    {:ok, naive} = NaiveDateTime.new(y, mo, d, h, mi, s)
    naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:second)
  end

  defp strip_utc_flag("!" <> rest), do: {rest, true}
  defp strip_utc_flag(format), do: {format, false}

  # The sandbox has no timezone database, so local time and UTC are
  # treated as identical. The utc? flag is parsed for compatibility with
  # the leading '!' but does not change the result.
  defp to_datetime(time, _utc?) do
    DateTime.from_unix!(time, :second)
  end

  defp date_table(%DateTime{} = dt, state) do
    yday = Date.day_of_year(DateTime.to_date(dt))
    # Lua wday: 1 = Sunday .. 7 = Saturday; Elixir: 1 = Monday .. 7 = Sunday.
    wday = rem(Date.day_of_week(DateTime.to_date(dt)), 7) + 1

    fields = %{
      "year" => dt.year,
      "month" => dt.month,
      "day" => dt.day,
      "hour" => dt.hour,
      "min" => dt.minute,
      "sec" => dt.second,
      "wday" => wday,
      "yday" => yday,
      "isdst" => false
    }

    {tref, state} = State.alloc_table(state, fields)
    {[tref], state}
  end

  defp strftime(format, %DateTime{} = dt) do
    Regex.replace(~r/%./, format, fn directive ->
      directive_value(directive, dt)
    end)
  end

  defp directive_value("%Y", dt), do: Integer.to_string(dt.year)
  defp directive_value("%y", dt), do: pad2(rem(dt.year, 100))
  defp directive_value("%m", dt), do: pad2(dt.month)
  defp directive_value("%d", dt), do: pad2(dt.day)
  defp directive_value("%H", dt), do: pad2(dt.hour)
  defp directive_value("%M", dt), do: pad2(dt.minute)
  defp directive_value("%S", dt), do: pad2(dt.second)
  defp directive_value("%p", dt), do: if(dt.hour < 12, do: "AM", else: "PM")
  defp directive_value("%A", dt), do: weekday_name(dt)
  defp directive_value("%a", dt), do: String.slice(weekday_name(dt), 0, 3)
  defp directive_value("%B", dt), do: month_name(dt)
  defp directive_value("%b", dt), do: String.slice(month_name(dt), 0, 3)
  defp directive_value("%j", dt), do: pad3(Date.day_of_year(DateTime.to_date(dt)))

  defp directive_value("%c", dt) do
    "#{String.slice(weekday_name(dt), 0, 3)} #{String.slice(month_name(dt), 0, 3)} " <>
      "#{pad2(dt.day)} #{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)} #{dt.year}"
  end

  defp directive_value("%x", dt), do: "#{pad2(dt.month)}/#{pad2(dt.day)}/#{pad2(rem(dt.year, 100))}"
  defp directive_value("%X", dt), do: "#{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)}"
  defp directive_value("%%", _dt), do: "%"
  defp directive_value(other, _dt), do: other

  @weekdays {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}
  @months {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
           "December"}

  defp weekday_name(%DateTime{} = dt) do
    elem(@weekdays, Date.day_of_week(DateTime.to_date(dt)) - 1)
  end

  defp month_name(%DateTime{} = dt), do: elem(@months, dt.month - 1)

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  # Monotonic clock origin so os.clock() reports elapsed seconds from a stable
  # reference. Seeded at library install (see install/1); the value lives in
  # :persistent_term, which is BEAM-global, so the first VM to install wins and
  # all later installs reuse that origin.
  defp boot_offset do
    case :persistent_term.get({__MODULE__, :boot}, nil) do
      nil ->
        now = :erlang.monotonic_time(:nanosecond)
        :persistent_term.put({__MODULE__, :boot}, now)
        now

      offset ->
        offset
    end
  end
end
