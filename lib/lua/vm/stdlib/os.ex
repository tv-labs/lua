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
  - `os.setlocale([locale [, category]])` - No-op returning "C".
  - `os.tmpname()` - A virtual name usable for a temporary file.
  - `os.remove(filename)` - Removes a file from the virtual filesystem.
  - `os.rename(from, to)` - Renames a file within the virtual filesystem.
  - `os.exit([code [, close]])` - Raises to unwind; sandbox cannot exit.

  Filesystem operations run against the VM's virtual filesystem
  (`state.vfs`), never the host disk.
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

  @impl true
  def lib_name, do: "os"

  @impl true
  def install(state) do
    # Seed the monotonic origin at install time so os.clock() measures from a
    # stable startup point rather than from whenever it is first called.
    boot_offset()

    os_table = %{
      "clock" => {:native_func, &os_clock/2},
      "date" => {:native_func, &os_date/2},
      "difftime" => {:native_func, &os_difftime/2},
      "exit" => {:native_func, &os_exit/2},
      "getenv" => {:native_func, &os_getenv/2},
      "remove" => {:native_func, &os_remove/2},
      "rename" => {:native_func, &os_rename/2},
      "setlocale" => {:native_func, &os_setlocale/2},
      "time" => {:native_func, &os_time/2},
      "time_ms" => {:native_func, &os_time_ms/2},
      "time_us" => {:native_func, &os_time_us/2},
      "tmpname" => {:native_func, &os_tmpname/2}
    }

    {tref, state} = State.alloc_table(state, os_table)
    State.set_global(state, "os", tref)
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
  defp os_getenv([name | _], state) when is_binary(name) do
    {[System.get_env(name)], state}
  end

  defp os_getenv([name | _], _state) do
    raise ArgumentError.type_error("os.getenv", 1, "string", Util.typeof(name))
  end

  defp os_getenv([], _state) do
    raise ArgumentError.value_expected("os.getenv", 1)
  end

  # os.setlocale([locale [, category]]) — no locale support in the
  # sandbox; report the "C" locale as active.
  defp os_setlocale(_args, state), do: {["C"], state}

  # os.tmpname() — a virtual name usable for a temporary file. The path lives
  # under the sandbox's virtual /tmp root; the VM never touches host paths.
  defp os_tmpname(_args, state) do
    name = "/tmp/lua_#{:erlang.unique_integer([:positive])}"
    {[name], state}
  end

  # os.remove(filename) — removes a file from the virtual filesystem. Returns
  # true on success, or (nil, message, errno) when the file cannot be removed.
  defp os_remove([filename | _], state) when is_binary(filename) do
    case State.vfs_rm(state, filename) do
      {:ok, state} -> {[true], state}
      {:error, error, state} -> {vfs_failure(filename, error), state}
    end
  end

  defp os_remove([arg | _], _state) do
    raise ArgumentError.type_error("os.remove", 1, "string", Util.typeof(arg))
  end

  defp os_remove([], _state) do
    raise ArgumentError.value_expected("os.remove", 1)
  end

  # os.rename(from, to) — renaming a file to itself is a successful no-op, as in
  # POSIX rename(2); short-circuit so we don't read/write/remove the same path.
  defp os_rename([path, path | _], state) when is_binary(path) do
    {[true], state}
  end

  # os.rename(from, to) — moves a file within the virtual filesystem by reading
  # the source, writing the destination, then removing the source. Returns true
  # on success, or (nil, message, errno) when any step fails. Each step carries
  # the path it operated on so the message names the path that actually failed.
  defp os_rename([from, to | _], state) when is_binary(from) and is_binary(to) do
    with {:ok, contents, state} <- with_path(from, State.vfs_read(state, from)),
         {:ok, state} <- with_path(to, State.vfs_write(state, to, contents)),
         {:ok, state} <- with_path(from, State.vfs_rm(state, from)) do
      {[true], state}
    else
      {:error, path, error, state} -> {vfs_failure(path, error), state}
    end
  end

  defp os_rename([from, to | _], _state) when is_binary(from) do
    raise ArgumentError.type_error("os.rename", 2, "string", Util.typeof(to))
  end

  defp os_rename([from | _], _state) do
    raise ArgumentError.type_error("os.rename", 1, "string", Util.typeof(from))
  end

  defp os_rename([], _state) do
    raise ArgumentError.value_expected("os.rename", 1)
  end

  # Tags a VFS result with the path the step operated on, so a `with` chain can
  # attribute a failure to the path that actually failed rather than a fixed one.
  defp with_path(_path, {:ok, _state} = ok), do: ok
  defp with_path(_path, {:ok, _contents, _state} = ok), do: ok
  defp with_path(path, {:error, error, state}), do: {:error, path, error, state}

  # Builds Lua's failure return for os.remove/os.rename: (nil, message, errno),
  # matching the reference contract of `nil, "<path>: <reason>", <errno>`.
  defp vfs_failure(path, %VFS.Error{} = error) do
    [nil, vfs_error_message(path, error), vfs_errno(error)]
  end

  # Maps a %VFS.Error{} into Lua's "<path>: <reason>" error string convention.
  defp vfs_error_message(path, %VFS.Error{kind: :enoent}), do: "#{path}: No such file or directory"
  defp vfs_error_message(path, %VFS.Error{message: message}), do: "#{path}: #{message}"

  # Maps a %VFS.Error{} kind onto its conventional POSIX errno integer, the
  # third value Lua 5.3 returns from os.remove/os.rename on failure.
  defp vfs_errno(%VFS.Error{kind: kind}) do
    case kind do
      :enoent -> 2
      :eio -> 5
      :eacces -> 13
      :eexist -> 17
      :enotdir -> 20
      :eisdir -> 21
      :einval -> 22
      :erofs -> 30
      :eloop -> 40
      :enotsup -> 95
      :exdev -> 18
      _ -> 0
    end
  end

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
