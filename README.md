# Description

SQLite3 library and an adapter for Ecto 3.x in one package (the minimum Ecto 3.x version is still TBD). It steps on the excellent [rusqlite](https://crates.io/crates/rusqlite) Rust crate.

**WARNING**: Not fully ready for use yet. Read the roadmap for details.

# Current status, priorities, and technical background

I am looking for the best Rust primitives and 3rd party libraries to use as less locks as possible when working with sqlite since it itself uses enough of them and I don't want the Rust code to do superfluous synchronization.

Apparently there are some sqlite operations that aren't threadsafe in serialized mode (the so-called "full mutex sqlite mode"). Context: https://github.com/rusqlite/rusqlite/issues/342#issuecomment-592624109. And a link to the official sqlite3 docs: https://sqlite.org/threadsafe.html

For these reasons, this library will always open sqlite connections in the so-called "no mutex" mode -- meaning that every time an sqlite operation is issued on the Elixir side, the Rust code will get a new sqlite connection from an internal pool so as to never share a single internal sqlite database handle between OTP processes. I haven't figured out how to balance the publicly exposed Erlang/Elixir pool with that internal Rust pool just yet, that's a high-prio task for the near future.

**CURRENTLY WORKING ON**: to achieve stable and predictable Rust code with minimal lock contention. I am investing hard in making the code readable and understandable -- not happy with its first working version so I am experimenting with various other solutions.

# Roadmap, goals, and TODO

- [x] Can open and close sqlite connections.
- [x] Can retrieve and set PRAGMA properties.
- [x] Can execute any arbitrary SQL statements but it does not return any records; only a number of records / tables / triggers / etc. which were affected by the statement.
- [x] Can execute SELECT statements without arguments (arguments must be already in the query string, yes yes SQL injection I know but hey, I am just trying to arrive at a first working version).
- [ ] **NEXT UP ON THE ELIXIR SIDE OF THE CODE**: Support all SQL operations -- insert, select, update, delete and all others (like creating triggers).
- [ ] Provide support for connection pooling (which it already has but it's currently only used internally in the Rust code; it has to be integrated with [Poolboy](https://github.com/devinus/poolboy) and/or Ecto 3.x in general).
- [ ] Provide an OTP wiring in the form of a [GenServer](https://hexdocs.pm/elixir/GenServer.html). Main idea is to centralize and serialize the write operations (INSERT, UPDATE, DELETE, DROP etc.) so the user doesn't accidentally delete a record and then try to update it.
- [ ] Integrate with Ecto 3.x.
- [ ] Provide first-class support for the [session extension](https://www.sqlite.org/sessionintro.html) so the users of the library can snapshot and isolate batches of changes (which are coincidentally also named changesets and patchsets; **not** to be mistaken with Ecto's [Changeset](https://hexdocs.pm/ecto/Ecto.Changeset.html#content)).

# Far future and potentially impossible goals

- To provide an optional strict mode with guidelines borrowed [from sqlite itself](https://sqlite.org/src/wiki?name=StrictMode). Additionally, this is going to involve automatically injecting sqlite triggers in the database that enforce proper types in every column (a la PostgreSQL), combined with runtime type checks -- pattern-matching and guards -- in the Elixir code. It's probably going to be clunky and not provide 100% guarantee but the author feels it's still going to be a huge improvement over the basically almost untyped raw sqlite.

# Installation

This package is not yet published on hex.pm. To use it, add this to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xqlite, github: "dimitarvp/xqlite"}
  ]
end
```

When I add it to hex.pm I'll start tagging it properly as well and then versions can be used normally.

# Technical notes

- Testing both the Elixir and the Rust side is a first priority. No matter what feature gets added, it comes with tests. Please do not ever rely on reverse-engineering the code. Implementation details _will_ be changing under your feet. I'll gradually be stabilizing the public contract of the library -- please do only lean on that.

- `Mix.Config` will not be used to configure this library. Every needed configuration will be provided to the library's function directly. Additionally, the future `GenServer` will likely be made to also carry configuration for convenience.

- Elixir 1.9's `Config` will not be used either. See [Avoid application configuration](https://hexdocs.pm/elixir/library-guidelines.html#avoid-application-configuration) by Elixir's authors.

- The `Xqlite.Config` module has been created but it's not used anywhere for now.
