defmodule Lua.VM.Stdlib.Os do
  @moduledoc """
  Lua 5.3 `os` standard library (sandbox-safe subset).

  Provides time and date facilities plus a handful of environment
  helpers. Functions that would touch the filesystem or spawn
  subprocesses are intentionally absent or stubbed, since the VM runs in
  an embedded sandbox.

  ## Functions

  - `os.time([table])` - Epoch seconds, optionally from a date table.
  - `os.clock()` - Approximate CPU time used, in seconds.
  - `os.difftime(t2, t1)` - Difference in seconds between two times.
  - `os.date([format [, time]])` - Formats a time as a string or table.
  - `os.getenv(name)` - Value of an environment variable, or nil.
  - `os.setlocale([locale [, category]])` - No-op returning "C".
  - `os.tmpname()` - A name usable for a temporary file.
  - `os.exit([code [, close]])` - Raises to unwind; sandbox cannot exit.
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
    os_table = %{
      "clock" => {:native_func, &os_clock/2},
      "date" => {:native_func, &os_date/2},
      "difftime" => {:native_func, &os_difftime/2},
      "exit" => {:native_func, &os_exit/2},
      "getenv" => {:native_func, &os_getenv/2},
      "setlocale" => {:native_func, &os_setlocale/2},
      "time" => {:native_func, &os_time/2},
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

  # os.tmpname() — a name usable for a temporary file.
  defp os_tmpname(_args, state) do
    name = Path.join(System.tmp_dir() || "/tmp", "lua_#{:erlang.unique_integer([:positive])}")
    {[name], state}
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

  # Monotonic clock origin captured at module load so os.clock() reports
  # elapsed seconds from a stable reference.
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
