# Fingerprints the working tree so a commit can prove a green `mix verify`
# ran on exactly this content.
#
#     elixir scripts/tree_fingerprint.exs           # print the fingerprint
#     elixir scripts/tree_fingerprint.exs --stamp   # write _build/verify.stamp
#     elixir scripts/tree_fingerprint.exs --check   # exit 1 unless the stamp
#                                                   # matches the tree now
#
# The fingerprint is a SHA-256 over the path and content of every tracked or
# untracked file git does not ignore (HEAD is deliberately not part of it: a
# commit changes HEAD but not the content that was verified). `mix verify`
# writes the stamp as its last step; the commit hook runs the check.

defmodule TreeFingerprint do
  @stamp Path.join("_build", "verify.stamp")

  def main(["--stamp"]) do
    with {:ok, fingerprint} <- fingerprint(),
         :ok <- File.mkdir_p("_build"),
         :ok <- File.write(@stamp, fingerprint <> "\n") do
      IO.puts("verify stamp written for " <> fingerprint)
    else
      {:error, reason} -> fail("cannot write the verify stamp: #{inspect(reason)}")
    end
  end

  def main(["--check"]) do
    with {:ok, fingerprint} <- fingerprint(),
         {:ok, stamped} <- read_stamp() do
      if String.trim(stamped) == fingerprint do
        IO.puts("verify stamp matches the working tree")
      else
        fail("the working tree changed since the last green `mix verify`; run it again")
      end
    else
      {:error, :enoent} -> fail("no verify stamp: run `mix verify` before committing")
      {:error, reason} -> fail("cannot check the verify stamp: #{inspect(reason)}")
    end
  end

  def main(_) do
    case fingerprint() do
      {:ok, fingerprint} -> IO.puts(fingerprint)
      {:error, reason} -> fail("cannot fingerprint the tree: #{inspect(reason)}")
    end
  end

  defp read_stamp, do: File.read(@stamp)

  defp fingerprint do
    with {:ok, listing} <-
           git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) do
      digest =
        listing
        |> String.split(<<0>>, trim: true)
        |> Enum.sort()
        |> Enum.reduce(:crypto.hash_init(:sha256), &hash_file/2)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  defp hash_file(path, acc) do
    case File.read(path) do
      {:ok, content} -> acc |> :crypto.hash_update(path) |> :crypto.hash_update(content)
      {:error, _} -> :crypto.hash_update(acc, path <> " (missing)")
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git, code, String.trim(out)}}
    end
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

TreeFingerprint.main(System.argv())
