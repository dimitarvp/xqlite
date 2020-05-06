# Description

SQLite3 library and an adapter for Ecto 3.x in one package (the minimum Ecto 3 version is still TBD).

**WARNING**: Not fully ready for use yet.

# Current status

- [x] Can open and close sqlite connections.
- [x] Can retrieve and set PRAGMA properties.
- [x] Can execute any arbitrary SQL statements but it does not return any records; only a number of records / tables / triggers / etc. which were affected by the statement.
- [ ] **Currently worked on**: Support all SQL operations -- insert, select, update, delete and all others (like creating triggers).
- [ ] Integrate with Ecto 3.x.
- [ ] Provide first-class support for the [session extension](https://www.sqlite.org/sessionintro.html) so the users of the library can snapshot and isolate batches of changes (which are coincidentally also named changesets and patchsets; **not** to be mistaken with Ecto's [Changeset](https://hexdocs.pm/ecto/Ecto.Changeset.html#content)).

# Roadmap and goals

- To provide enough functions and options for working with sqlite so as to make a wide variety of sqlite work in Elixir easy to achieve. This includes but is not limited to: application databases, caches, one-file backups, transformed public data sets like Wikipedia or Common Crawl.

- The main module has to work with sqlite via an opaque connection handle (reference-counted from the Rust code side).

- To provide OTP wiring ([GenServer](https://hexdocs.pm/elixir/GenServer.html)) to centralise and serialise writes to the  sqlite DB. This can be achieved even now without a `GenServer` but the order of the write operations cannot be guaranteed. The `GenServer` will help with that.

- To provide an [Ecto](https://hexdocs.pm/ecto/Ecto.html) 3.x adapter, complete with connection pooling and everything that the PostgreSQL and MySQL adapters offer (exact goals TBD).

# Future, possibly non-doable goals

- To provide an optional strict mode with guidelines borrowed [from sqlite itself](https://sqlite.org/src/wiki?name=StrictMode). Additionally, this is going to involve automatically injecting sqlite triggers in the database that enforce proper types in every column (a la PostgreSQL), combined with runtime type checks -- pattern-matching and guards -- in the Elixir code. It's probably going to be clunky and not provide 100% guarantee but the author feels it's still going to be a huge improvement over the basically almost untyped raw sqlite.

# Installation

This package is not yet published on Hex.PM. To use it, add this to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xqlite, github: "dimitarvp/xqlite"}
  ]
end
```

# Technical notes

- `Mix.Config` will not be used to configure this library. Every needed configuration will be provided to the library's function directly. Additionally, the future `GenServer` will likely be made to also carry configuration for convenience.

- Elixir 1.9's `Config` will not be used either. See [Avoid application configuration](https://hexdocs.pm/elixir/library-guidelines.html#avoid-application-configuration) by Elixir's authors.

- The `Xqlite.Config` module has been created but for now it's not used anywhere for now.
