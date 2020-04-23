defmodule Xqlite.MixProject do
  use Mix.Project

  @name "Xqlite"
  @version "0.1.1"

  def project do
    [
      app: :xqlite,
      version: @version,
      elixir: "~> 1.7",
      name: @name,
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      aliases: aliases(),
      deps: deps(),
      compilers: [:rustler] ++ Mix.compilers(),
      rustler_crates: rustler_crates(),

      # hex
      description: description(),
      package: package(),

      # testing
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.circle": :test
      ],

      # type checking
      dialyzer: dialyzer(Mix.env())
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Xqlite.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # dependencies that are always included.

      {:floki, "~> 0.23"},
      {:jason, "~> 1.2"},
      {:rustler, "~> 0.22-rc"},

      # dev / test dependencies.

      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0-rc", only: :dev, runtime: false},
      {:ex_doc, "~> 0.20", only: :dev, runtime: false},
      {:excoveralls, "~> 0.11", only: :test}
    ]
  end

  defp docs(),
    do: [
      source_ref: "v#{@version}",
      main: "readme",
      extras: ["README.md"]
    ]

  defp rustler_crates(), do: [xqlitenif: [mode: :release]]

  defp description(), do: "SQLite DB library utilising the rusqlite Rust crate"

  defp package() do
    [
      licenses: ["MIT"],
      links: %{
        "Github" => "https://github.com/dimitarvp/xqlite",
        "Hexdocs" => "https://hexdocs.pm/xqlite"
      }
    ]
  end

  defp dialyzer(_) do
    []
  end

  defp aliases do
    [
      c: "compile",
      f: ["format", "cmd cargo fmt --manifest-path native/xqlitenif/Cargo.toml"]
    ]
  end
end
