defmodule Xqlite.MixProject do
  use Mix.Project

  @name "Xqlite"

  def project do
    [
      app: :xqlite,
      version: "0.2.9",
      elixir: "~> 1.15",
      name: @name,
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      deps: deps(),
      compilers: Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # hex
      description: description(),
      package: package(),

      # testing
      test_coverage: [tool: ExCoveralls],

      # type checking
      dialyzer: dialyzer(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.circle": :test,
        "test.seq": :test
      ]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37.1", runtime: false},

      # dev / test.
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.20", only: :dev, runtime: false},
      {:excoveralls, "~> 0.11", only: :test}
    ]
  end

  defp docs() do
    [
      main: "readme",
      name: "Xqlite",
      source_url: "https://github.com/dimitarvp/xqlite",
      source_ref: "v0.2.9",
      extras: ["README.md", "LICENSE.md"],
      groups_for_modules: [
        "High-Level API": [
          Xqlite,
          Xqlite.Pragma,
          Xqlite.StreamResourceCallbacks
        ],
        "Schema Structs": [
          Xqlite.Schema.ColumnInfo,
          Xqlite.Schema.DatabaseInfo,
          Xqlite.Schema.ForeignKeyInfo,
          Xqlite.Schema.IndexColumnInfo,
          Xqlite.Schema.IndexInfo,
          Xqlite.Schema.SchemaObjectInfo,
          Xqlite.Schema.Types
        ],
        "Low-Level NIFs": [
          XqliteNIF
        ],
        "Internal Helpers": [
          Xqlite.PragmaUtil,
          Xqlite.TestUtil
        ]
      ]
    ]
  end

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

  defp dialyzer(_env) do
    [
      # Specifies the directory where core PLTs (OTP, Elixir stdlib) are stored.
      plt_core_path: "priv/plts/",
      # Specifies the path to the final project PLT file, which includes dependencies.
      # Using {:no_warn, ...} suppresses warnings if the file doesn't exist initially.
      plt_file: {:no_warn, "priv/plts/core.plt"},
      plt_add_apps: [:mix]
      # flags: ["-Wunmatched_returns", ...],
    ]
  end
end
