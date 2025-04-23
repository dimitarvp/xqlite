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
      compilers: Mix.compilers(),

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
        "coveralls.circle": :test,
        t: :test
      ],

      # type checking
      dialyzer: dialyzer(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # dependencies that are always included.

      {:rustler, "~> 0.36.1", runtime: false},

      # dev / test dependencies.

      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
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

  defp description(), do: "An Elixir SQLite database library utilising the rusqlite Rust crate"

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
      f: ["format", "cmd cargo fmt --manifest-path native/xqlitenif/Cargo.toml"],
      t: "test"
    ]
  end
end
