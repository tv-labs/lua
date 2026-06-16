defmodule Lua.VFS do
  @moduledoc """
  An in-memory virtual filesystem backing the sandboxed VM.

  The VM is virtual by default: filesystem-touching operations (`require`,
  `loadfile`/`dofile`, the `io` library, and the file-oriented `os` functions)
  read and write here instead of the host disk, so a sandboxed script can never
  reach the real machine. Embedding hosts seed it (e.g. `Lua.write_file/3`,
  `Lua.put_dep/3`) and harvest from it (`Lua.read_file/2`).

  Files are stored as a flat map keyed by **normalized absolute path**
  (`"/a/b.lua" => contents`); directories are implicit (a path is a directory
  when some stored key is nested beneath it). There is no host I/O and no
  pluggable backend — the boundary is entirely in-tree.

  Errors are tagged atoms that map onto Lua's `nil, message, errno` `io`/`os`
  contract: `:enoent` (no such file), `:eisdir` (path is a directory), and
  `:einval` (path is not absolute).
  """

  defstruct files: %{}

  @type path :: binary()
  @type error :: :enoent | :eisdir | :einval
  @type t :: %__MODULE__{files: %{optional(path()) => binary()}}

  @doc """
  Returns a new, empty virtual filesystem.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Reads the contents of `path`.

  Returns `{:ok, contents}`, `{:error, :enoent}` when the file is absent,
  `{:error, :eisdir}` when `path` names a directory, or `{:error, :einval}`
  when `path` is not absolute.
  """
  @spec read(t(), path()) :: {:ok, binary()} | {:error, error()}
  def read(%__MODULE__{files: files}, path) do
    with {:ok, norm} <- normalize(path) do
      cond do
        Map.has_key?(files, norm) -> {:ok, Map.fetch!(files, norm)}
        directory?(files, norm) -> {:error, :eisdir}
        true -> {:error, :enoent}
      end
    end
  end

  @doc """
  Writes `contents` to `path`, creating or overwriting the file.

  Returns `{:ok, vfs}` with the updated filesystem, or `{:error, :eisdir}` /
  `{:error, :einval}`. Parent directories are implicit and need not exist.
  """
  @spec write(t(), path(), binary()) :: {:ok, t()} | {:error, error()}
  def write(%__MODULE__{files: files} = vfs, path, contents) when is_binary(contents) do
    with {:ok, norm} <- normalize(path) do
      if directory?(files, norm) do
        {:error, :eisdir}
      else
        {:ok, %{vfs | files: Map.put(files, norm, contents)}}
      end
    end
  end

  @doc """
  Removes the file at `path`.

  Returns `{:ok, vfs}`, `{:error, :enoent}` when absent, `{:error, :eisdir}`
  when `path` names a directory, or `{:error, :einval}`.
  """
  @spec rm(t(), path()) :: {:ok, t()} | {:error, error()}
  def rm(%__MODULE__{files: files} = vfs, path) do
    with {:ok, norm} <- normalize(path) do
      cond do
        Map.has_key?(files, norm) -> {:ok, %{vfs | files: Map.delete(files, norm)}}
        directory?(files, norm) -> {:error, :eisdir}
        true -> {:error, :enoent}
      end
    end
  end

  @doc """
  Returns `true` when `path` names an existing file or implicit directory.

  A non-absolute path is never present and returns `false`.
  """
  @spec exists?(t(), path()) :: boolean()
  def exists?(%__MODULE__{files: files}, path) do
    case normalize(path) do
      {:ok, norm} -> Map.has_key?(files, norm) or directory?(files, norm)
      {:error, _} -> false
    end
  end

  @doc """
  Normalizes an absolute path, resolving `.` and `..` segments.

  Returns `{:ok, normalized}` for an absolute path (`"/a/./b/../c"` ->
  `"/a/c"`), or `{:error, :einval}` for a relative path. `..` at the root is a
  no-op, matching POSIX.
  """
  @spec normalize(path()) :: {:ok, path()} | {:error, :einval}
  def normalize("/" <> _ = path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [_ | rest] -> rest
        "..", [] -> []
        segment, acc -> [segment | acc]
      end)
      |> Enum.reverse()

    {:ok, "/" <> Enum.join(segments, "/")}
  end

  def normalize(_path), do: {:error, :einval}

  # A normalized path is a directory when some stored key is nested beneath it.
  defp directory?(files, norm) do
    prefix = norm <> "/"
    Enum.any?(files, fn {key, _} -> String.starts_with?(key, prefix) end)
  end
end
