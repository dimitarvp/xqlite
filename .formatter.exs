[
  plugins: [Quokka],
  # xqlitenif.ex is excluded from Quokka (NOT from plain formatting): its
  # `use RustlerPrecompiled` block needs the `@version` attribute defined
  # textually above it, and Quokka's module-directive sorting moves such
  # definitions below `use`, breaking compilation.
  quokka: [files: %{excluded: ["lib/xqlite/xqlitenif.ex"]}],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 95
]
