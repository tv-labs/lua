defmodule DemoWeb.PageControllerTest do
  use DemoWeb.ConnCase

  alias Website.Benchmarks

  test "GET / renders the Lua showcase landing page", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Lua, on the"
    assert body =~ "Playground"
    assert body =~ "Tour"
  end

  describe "GET /benchmarks" do
    test "renders a column per recorded version", %{conn: conn} do
      body = conn |> get(~p"/benchmarks") |> html_response(200)

      for version <- Benchmarks.versions() do
        assert body =~ version
      end
    end

    test "renders every row's recorded value rather than a placeholder", %{conn: conn} do
      body = conn |> get(~p"/benchmarks") |> html_response(200)

      for row <- Benchmarks.rows(), version <- Benchmarks.versions() do
        value = Benchmarks.value(row, version)

        assert value, "#{row.label} has no value for #{version}"
        assert body =~ value, "#{row.label}/#{version} (#{value}) missing from the page"
      end
    end

    test "links the campaign report it was written from", %{conn: conn} do
      body = conn |> get(~p"/benchmarks") |> html_response(200)

      assert body =~ "bench_results/#{Benchmarks.report()}"
    end

    test "is reachable from the site navigation", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ ~p"/benchmarks"
    end
  end

  describe "recorded results" do
    test "every row resolves against every recorded version" do
      for row <- Benchmarks.rows(), version <- Benchmarks.versions() do
        assert is_binary(Benchmarks.value(row, version)),
               "#{row.label} did not resolve for #{version} — check the case-name normalisation"
      end
    end

    test "ratios are taken against the same-run control" do
      for row <- Benchmarks.rows(), version <- Benchmarks.versions() do
        assert is_float(Benchmarks.ratio(row, version)),
               "#{row.label}/#{version} has no ratio — control job #{row.vs} missing?"
      end
    end

    test "versions are ordered oldest to newest" do
      assert Benchmarks.versions() ==
               Enum.sort(Benchmarks.versions(), &(Version.compare(&1, &2) != :gt))

      assert Benchmarks.latest() == List.last(Benchmarks.versions())
    end
  end
end
