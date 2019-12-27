# Description

SQLite3 library and an adapter for Ecto 3.1+ in one package.

**WARNING**: Not ready for use yet, still in development.

# Current status

- Can open and close sqlite connections.
- Can retrieve and set PRAGMA properties.
- **UP NEXT**: Support all SQL operations (insert, select, update etc.). This will likely involve a lot of copy-paste from [sqlitex](https://github.com/elixir-sqlite/sqlitex) since this author's goal is to marry sqlite and Ecto 3.1+. Any functional refinements and shaking of external dependencies are a secondary priority.

# Roadmap and goals

- To provide enough functions and options for working with sqlite so as to make a wide variety of sqlite work in Elixir easy to achieve. This includes but is not limited to: application databases, caches, one-file backups, transformed public data sets like Wikipedia or Common Crawl.

- The main module has to work with sqlite via an opaque connection handle (identical to the one that the Erlang library [esqlite](https://github.com/mmzeeman/esqlite) returns since this library uses it).

- To provide OTP wiring, namely a [GenServer](https://hexdocs.pm/elixir/GenServer.html) that can be inserted in the library user's supervision tree. Or simply to centralise the access to an sqlite database if the user so desires (note that this is not mandated by sqlite since by default it allows concurrent read access; using the `GenServer` would mostly be helpful if you want to avoid concurrent write access which is not supported).

- To provide an [Ecto](https://hexdocs.pm/ecto/Ecto.html) 3.1+ adapter.

# Future, possibly non-doable goals

- To provide as strict as possible typing mode which is mostly going to involve installing sqlite triggers in the database, combined with runtime type checks (pattern-matching and guards) in the Elixir code. It's probably going to be clunky and not provide 100% guarantee but the author feels it's still going to be a huge improvement over the basically untyped raw sqlite.

- Stop integrating with Erlang's [esqlite](https://github.com/mmzeeman/esqlite) library (and by extension, Elixir's [sqlitex](https://github.com/elixir-sqlite/sqlitex) library), and move to Rust's [rusqlite](https://github.com/jgallagher/rusqlite) and utilise [Rustler](https://github.com/rusterlium/rustler) to facilitate the connection.

# Installation

This package can be installed by adding `xqlite` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xqlite, "~> 0.1"}
  ]
end
```

Documentation: [https://hexdocs.pm/xqlite](https://hexdocs.pm/xqlite).

# Technical notes

- `Mix.Config` will not be used to configure this library since it's deprecated in Elixir 1.9.

- Elixir 1.9's `Config` will not be used either. See [Avoid application configuration](https://hexdocs.pm/elixir/library-guidelines.html#avoid-application-configuration) by Elixir's authors.

- The library is configured via the `Xqlite.Config` structure which is going to be passed around in the raw sqlite functions and also stored as a `GenServer` state in the OTP wiring part of the library. _No application configuration will ever be involved_. You either carry your configuration and pass it around, or make a `GenServer` remember it for you.
