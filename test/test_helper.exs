# Compile the test SQLite extension for load_extension tests.
test_ext_dir = Path.join([__DIR__, "support", "ext"])
test_ext_src = Path.join(test_ext_dir, "xqlite_test_ext.c")
test_ext_out = Path.join(test_ext_dir, "xqlite_test_ext")

cargo_home = System.get_env("CARGO_HOME") || Path.join(System.user_home!(), ".cargo")

sqlite_header_dir =
  Path.wildcard(Path.join([cargo_home, "registry", "src", "*", "libsqlite3-sys-*", "sqlite3"]))
  |> Enum.sort()
  |> List.last()

unless sqlite_header_dir do
  raise "Cannot find sqlite3ext.h in Cargo registry under #{cargo_home}"
end

{ext_suffix, compiler_args} =
  case :os.type() do
    {:unix, :darwin} ->
      {"dylib",
       fn src, out, inc -> ["cc", ["-shared", "-fPIC", "-I", inc, "-o", out, src]] end}

    {:unix, _} ->
      {"so", fn src, out, inc -> ["cc", ["-shared", "-fPIC", "-I", inc, "-o", out, src]] end}

    {:win32, _} ->
      {"dll",
       fn src, out, inc ->
         ["gcc", ["-shared", "-I", inc, "-o", out, src]]
       end}
  end

out_file = "#{test_ext_out}.#{ext_suffix}"

unless File.exists?(out_file) && File.stat!(out_file).mtime >= File.stat!(test_ext_src).mtime do
  [cmd | [args]] = compiler_args.(test_ext_src, out_file, sqlite_header_dir)

  case System.cmd(cmd, args, stderr_to_stdout: true) do
    {_, 0} ->
      :ok

    {output, code} ->
      raise """
      Failed to compile test extension (exit code #{code}).
      Command: #{cmd} #{Enum.join(args, " ")}
      Output: #{output}
      """
  end
end

ExUnit.start()
