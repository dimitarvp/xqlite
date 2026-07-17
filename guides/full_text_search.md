# Full-text search with FTS5

FTS5 is compiled into xqlite's bundled SQLite (`ENABLE_FTS5` — check
`XqliteNIF.compile_options/1` if you doubt it). It is SQLite's answer to
"I want a GIN index and `tsquery`": an inverted index over your text
columns, queried with a small match language, ranked with BM25. No
extension loading, no extra process — it's already there.

## A searchable table in two statements

```elixir
{:ok, conn} = Xqlite.open_in_memory()

:ok =
  XqliteNIF.execute_batch(conn, """
  CREATE TABLE articles (id INTEGER PRIMARY KEY, title TEXT, body TEXT);
  CREATE VIRTUAL TABLE articles_fts USING fts5(
    title, body,
    content = 'articles',
    content_rowid = 'id'
  );
  """)
```

`content = 'articles'` makes this an **external-content** table: the
index stores only tokens, not a second copy of your text — the
canonical rows stay in `articles`. The price of that layout is that
you must keep the index in sync yourself, and the canonical way is
triggers:

```elixir
:ok =
  XqliteNIF.execute_batch(conn, """
  CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, body)
    VALUES (new.id, new.title, new.body);
  END;
  CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
  END;
  CREATE TRIGGER articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO articles_fts(rowid, title, body)
    VALUES (new.id, new.title, new.body);
  END;
  """)
```

(The odd-looking `'delete'` insert is FTS5's command syntax — external
content tables are told about deletions, they don't observe them.)

## Querying

```elixir
{:ok, _} =
  XqliteNIF.execute(
    conn,
    "INSERT INTO articles (title, body) VALUES (?1, ?2)",
    ["SQLite and the BEAM", "Cancellable queries keep schedulers happy"]
  )

{:ok, result} =
  XqliteNIF.query(
    conn,
    """
    SELECT a.id, a.title, bm25(articles_fts) AS rank
    FROM articles_fts
    JOIN articles a ON a.id = articles_fts.rowid
    WHERE articles_fts MATCH ?1
    ORDER BY rank
    """,
    ["schedulers"]
  )
```

The match language covers the usual needs: `"exact phrase"`,
`prefix*`, `title:beam` (column filter), `sqlite AND (beam OR
erlang)`, `NEAR(sqlite beam, 5)`. `bm25()` returns *lower is better*
— `ORDER BY rank` ascending gives best-first.

Snippets and highlighting are built in:

```sql
SELECT highlight(articles_fts, 0, '<b>', '</b>') AS title_hl,
       snippet(articles_fts, 1, '<b>', '</b>', '…', 12) AS excerpt
FROM articles_fts
WHERE articles_fts MATCH ?1
```

## Through the Ecto adapter

Everything above is plain SQL, so with
[xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) it belongs
in a migration's `execute/2` (the virtual table + triggers) and in
`Repo.query!/2` or `fragment/1` for the match queries:

```elixir
Repo.query!(
  "SELECT a.* FROM articles_fts JOIN articles a ON a.id = articles_fts.rowid " <>
    "WHERE articles_fts MATCH ?1 ORDER BY bm25(articles_fts)",
  [search_term]
)
```

The match term is a bound parameter — never interpolate user input
into the query string.

## Operational notes

- **Tokenizers.** The default `unicode61` folds case and diacritics.
  `porter` adds English stemming: `USING fts5(..., tokenize =
  'porter unicode61')`. `trigram` enables `LIKE`/`GLOB`-style substring
  search on the index.
- **Rebuilds.** After bulk-loading the content table directly, rebuild
  the index in one command:
  `INSERT INTO articles_fts(articles_fts) VALUES ('rebuild')`.
- **Integrity.** `INSERT INTO articles_fts(articles_fts, rank) VALUES
  ('integrity-check', 1)` verifies index-vs-content consistency.
- **Size/speed knobs.** `'optimize'` merges the b-trees after heavy
  write churn; `detail = 'column'` or `'none'` shrink the index if you
  don't need phrase/NEAR queries.
- FTS5 tables ignore `STRICT` and constraints — they are indexes, not
  data owners. Keep constraints on the content table.
