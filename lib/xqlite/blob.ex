defmodule Xqlite.Blob do
  @moduledoc """
  Wraps bytes that must reach SQLite as a `BLOB`, whatever they contain.

  A plain Elixir binary bound as a parameter is stored as `TEXT` when its
  bytes are valid UTF-8 and as a `BLOB` otherwise. That rule is what makes
  ordinary Elixir strings arrive as text, and it stays. The cost is that raw
  bytes land in two different storage classes: roughly one in fourteen
  thousand random 16-byte values — a UUID, a key, a piece of ciphertext —
  happens to decode as UTF-8 and is stored as `TEXT`. `typeof` then differs
  between rows that hold the same kind of data, SQLite sorts every `TEXT`
  value before every `BLOB` one, a `UNIQUE` column accepts the same bytes
  twice because the two classes are not equal, and a STRICT table with a
  `BLOB` column rejects the row outright.

  Wrapping the bytes removes the guesswork:

      # Wrapped: stored as a BLOB, whatever the bytes are.
      {:ok, %Xqlite.Result{rows: [["blob"]]}} =
        Xqlite.query(conn, "SELECT typeof(?1)", [%Xqlite.Blob{bytes: "0123456789abcdef"}])

      # Plain: those sixteen bytes are valid UTF-8, so SQLite stores TEXT.
      {:ok, %Xqlite.Result{rows: [["text"]]}} =
        Xqlite.query(conn, "SELECT typeof(?1)", ["0123456789abcdef"])

  It is accepted everywhere a parameter value is accepted — in a positional
  list and as the value of a keyword pair — by `Xqlite.query/4`,
  `Xqlite.execute/4`, their cancellable forms, `Xqlite.stream/4`,
  `Xqlite.bind/3`, `Xqlite.explain_analyze/4` and the matching `XqliteNIF`
  functions. `execute_batch/2` takes no parameters and is unaffected. No
  built-in type extension claims it, so it passes the chain untouched even
  with `:type_extensions` set.

  `bytes` must be a binary. Anything else is refused with
  `{:error, {:invalid_blob_bytes, %{position: n, type: t}}}`, where `n` is
  the parameter's one-based position in the list you passed and `t` is the
  type of the value found in `bytes`.

  ## A value read back is never wrapped

  A result row carries plain Elixir values, so a `BLOB` column comes back as
  a plain binary with nothing to say which storage class it came from.
  Reading a value and writing it straight back therefore moves it to `TEXT`
  whenever its bytes are valid UTF-8, unless the code that writes it wraps it
  again.
  """

  defstruct [:bytes]

  @typedoc """
  A parameter whose bytes are bound as a `BLOB` rather than classified by
  their contents.
  """
  @type t :: %__MODULE__{bytes: binary()}
end
