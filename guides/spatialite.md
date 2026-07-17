# Spatial data with SpatiaLite

SQLite has no PostGIS built in, but the ecosystem's answer —
[SpatiaLite](https://www.gaia-gis.it/fossil/libspatialite/index) — is
a loadable extension, and xqlite's extension loading is the doorway.
This guide is **doc-first**: xqlite does not bundle or test SpatiaLite
in CI; it documents the pattern that works with the machinery xqlite
ships (opt-in extension loading against the bundled SQLite — loadable
extensions use SQLite's function-pointer ABI, so the bundled build
loads system-installed extension binaries fine).

## Installing the extension binary

The extension is `mod_spatialite`, installed per platform:

- Debian/Ubuntu: `apt install libsqlite3-mod-spatialite`
  (lands as `/usr/lib/x86_64-linux-gnu/mod_spatialite.so`)
- macOS: `brew install libspatialite`
- Windows: the `mod_spatialite` DLL bundles from gaia-gis.it
  (put the whole directory on `PATH` — the DLL has sibling
  dependencies)

## Loading it

Extension loading is disabled by default and gated twice (the
Elixir-side opt-in and SQLite's own flag):

```elixir
{:ok, conn} = Xqlite.open("geo.db")

:ok = Xqlite.enable_load_extension(conn, true)
{:ok, _} = Xqlite.load_extension(conn, "mod_spatialite")
# Windows or non-standard paths: pass the full path to the library.
:ok = Xqlite.enable_load_extension(conn, false)
```

Re-disabling after loading is good hygiene: `load_extension` is a
per-connection capability you rarely want left open.

First use of a database needs the metadata tables (one-time, slow —
it creates the spatial reference systems catalog):

```elixir
{:ok, _} = XqliteNIF.query(conn, "SELECT InitSpatialMetaData(1)", [])
```

## A spatial table

```elixir
:ok = XqliteNIF.execute_batch(conn, """
CREATE TABLE places (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
""")

{:ok, _} =
  XqliteNIF.query(
    conn,
    "SELECT AddGeometryColumn('places', 'geom', 4326, 'POINT', 'XY')",
    []
  )

{:ok, _} =
  XqliteNIF.execute(
    conn,
    "INSERT INTO places (name, geom) VALUES (?1, GeomFromText(?2, 4326))",
    ["Sofia", "POINT(23.3219 42.6977)"]
  )
```

Distance queries, in meters, on geographic coordinates:

```elixir
{:ok, result} =
  XqliteNIF.query(
    conn,
    """
    SELECT name,
           ST_Distance(geom, GeomFromText(?1, 4326), 1) AS meters
    FROM places
    ORDER BY meters
    LIMIT 10
    """,
    ["POINT(23.3 42.7)"]
  )
```

For large tables add the R*Tree-backed spatial index (xqlite's bundled
SQLite compiles R*Tree in) and use it explicitly:

```sql
SELECT CreateSpatialIndex('places', 'geom');

SELECT p.name
FROM places p
WHERE p.rowid IN (
  SELECT rowid FROM SpatialIndex
  WHERE f_table_name = 'places' AND search_frame = BuildMbr(?1, ?2, ?3, ?4)
)
```

SpatiaLite's spatial index is *opt-in per query* — the `SpatialIndex`
virtual-table subquery is the documented pattern, not something the
planner applies for you.

## Through the Ecto adapter

With [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3), do the
loading at connect time per pooled connection — a named process is not
needed; use the repo's `custom_pragmas`-adjacent hook point, i.e. run
the load in your own `after_connect`-style wrapper via
`XqliteEcto3.with_xqlite/3`, or simplest: load lazily in the code
paths that need spatial SQL. Geometry columns arrive as BLOBs at the
Ecto level; treat spatial SQL as `fragment/1` / `Repo.query!/2`
territory. First-class geometry types are out of the adapter's current
scope (`Geo`-style types would sit at the application layer).

## Honest caveats

- Not bundled, not CI-tested by xqlite — platform availability and
  version drift are yours to own. The extension ABI itself is stable.
- `InitSpatialMetaData` inflates the database by several MB (the SRS
  catalog). Run it once per database, not per connection.
- In-memory databases work for experimentation, but every new
  `:memory:` connection starts blank — metadata init included.
