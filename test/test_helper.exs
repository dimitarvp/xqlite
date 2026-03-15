# Compile the test SQLite extension for load_extension tests.
test_ext_dir = Path.join([__DIR__, "support", "ext"])
test_ext_src = Path.join(test_ext_dir, "xqlite_test_ext.c")
test_ext_out = Path.join(test_ext_dir, "xqlite_test_ext")

sqlite_header_dir =
  Path.wildcard(
    Path.join([
      System.user_home!(),
      ".cargo",
      "registry",
      "src",
      "**",
      "libsqlite3-sys-*",
      "sqlite3"
    ])
  )
  |> Enum.sort()
  |> List.last()

if sqlite_header_dir && File.exists?(test_ext_src) do
  ext_suffix = if :os.type() == {:unix, :darwin}, do: "dylib", else: "so"
  out_file = "#{test_ext_out}.#{ext_suffix}"

  unless File.exists?(out_file) && File.stat!(out_file).mtime >= File.stat!(test_ext_src).mtime do
    {_, 0} =
      System.cmd("cc", [
        "-shared",
        "-fPIC",
        "-I",
        sqlite_header_dir,
        "-o",
        out_file,
        test_ext_src
      ])
  end
end

ExUnit.start()
