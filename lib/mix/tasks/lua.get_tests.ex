defmodule Mix.Tasks.Lua.GetTests do
  @moduledoc """
  Downloads the official Lua 5.3 test suite.

  The test suite is downloaded from https://www.lua.org/tests/ and
  extracted to test/lua53_tests/.

  ## Usage

      mix lua.get_tests

  ## Options

    * `--version` - Lua version to download (default: 5.3.4)

  ## License

  The Lua test suite is distributed under the MIT license.
  Copyright © 1994–2025 Lua.org, PUC-Rio.
  See https://www.lua.org/license.html for details.
  """

  use Mix.Task

  # Suppress dialyzer warnings for Mix module functions (compile-time only)
  @dialyzer {:nowarn_function,
             run: 1, download_file: 2, extract_tarball: 2, remove_unnecessary_files: 1}

  @shortdoc "Downloads the Lua 5.3 test suite"
  @default_version "5.3.4"
  @base_url "https://www.lua.org/tests"

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [version: :string])
    version = Keyword.get(opts, :version, @default_version)

    test_dir = Path.join([File.cwd!(), "test", "lua53_tests"])
    tarball = "lua-#{version}-tests.tar.gz"
    url = "#{@base_url}/#{tarball}"

    Mix.shell().info("Downloading Lua #{version} test suite...")
    Mix.shell().info("From: #{url}")

    # Create test directory
    File.mkdir_p!(test_dir)

    # Download the tarball
    tarball_path = Path.join(test_dir, tarball)

    case download_file(url, tarball_path) do
      :ok ->
        Mix.shell().info("Downloaded to: #{tarball_path}")

        # Extract the tarball
        Mix.shell().info("Extracting tests...")
        extract_tarball(tarball_path, test_dir)

        # Clean up
        File.rm!(tarball_path)

        # Remove C code and test libraries we don't need
        remove_unnecessary_files(test_dir)

        Mix.shell().info("✓ Lua #{version} test suite ready in #{test_dir}")

      {:error, reason} ->
        Mix.raise("Failed to download test suite: #{reason}")
    end
  end

  defp download_file(url, dest) do
    case System.cmd("curl", ["-L", "-o", dest, url], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> {:error, output}
    end
  end

  defp extract_tarball(tarball_path, dest_dir) do
    extracted_dir = Path.join(dest_dir, Path.basename(tarball_path, ".tar.gz"))

    # Extract
    case System.cmd("tar", ["-xzf", tarball_path, "-C", dest_dir], stderr_to_stdout: true) do
      {_output, 0} ->
        # Move files from extracted directory to test_dir
        File.ls!(extracted_dir)
        |> Enum.each(fn file ->
          src = Path.join(extracted_dir, file)
          dest = Path.join(dest_dir, file)

          # Remove destination if it exists
          if File.exists?(dest), do: File.rm_rf!(dest)

          File.rename!(src, dest)
        end)

        # Remove the extracted directory
        File.rm_rf!(extracted_dir)
        :ok

      {output, _} ->
        Mix.raise("Failed to extract tarball: #{output}")
    end
  end

  defp remove_unnecessary_files(test_dir) do
    # Remove C code directories - we don't need them for testing our Elixir implementation
    ["libs", "ltests"]
    |> Enum.each(fn dir ->
      path = Path.join(test_dir, dir)
      if File.exists?(path), do: File.rm_rf!(path)
    end)

    Mix.shell().info("Cleaned up unnecessary C files")
  end
end
