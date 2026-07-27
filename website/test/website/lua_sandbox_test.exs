defmodule Website.LuaSandboxTest do
  @moduledoc """
  Pins that `run/1` leaves the caller alone.

  The worker is `spawn_link`ed so its death is observable, and `run/1` traps
  exits only for its own duration. Any exit signal that escapes that window
  lands on a caller that is no longer trapping and takes it down — so `run/1`
  has to cut the link itself rather than hope the signal beats the restore.
  """

  use ExUnit.Case, async: true

  alias Website.LuaSandbox

  @timeout_source """
  local n = 0
  while true do
    n = n + 1
  end
  """

  test "a snippet stopped by the wall-clock timeout does not kill a non-trapping caller" do
    parent = self()

    caller =
      spawn(fn ->
        result = LuaSandbox.run(@timeout_source)
        # Keep working after `run/1` returns: a late exit signal has to have
        # somewhere to land for the race to be observable.
        Process.sleep(150)
        send(parent, {:survived, result.status})
      end)

    ref = Process.monitor(caller)

    assert_receive {:survived, :timeout}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 1_000
  end

  test "a snippet that finishes leaves nothing in the caller's mailbox" do
    Process.flag(:trap_exit, true)

    assert %{status: :ok, returns: ["3"]} = LuaSandbox.run("return 1 + 2")

    refute_receive {:EXIT, _pid, _reason}, 100
  end
end
