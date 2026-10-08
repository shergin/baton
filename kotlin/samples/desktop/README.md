# Rick and Morty, on the desktop

The public Rick and Morty API (`https://rickandmortyapi.com/graphql`)
through the Kotlin runtime, in Compose for Desktop; the Kotlin counterpart
of `examples/RickAndMorty`. The characters, a page at a time, beside the
detail of the one selected: its header, which the list fetched and the
`character` lookup finds in the store, and its episodes, which only the
detail fetches.

- `baton.json` names the schema under `spec/rickandmorty/`, the lookups,
  and the package of the shared file.
- The hosts are the `.kt` files: `@Fragment` on the composable that renders
  a lens, `@Query` on the one that resolves an operation value with
  `rememberQuery`, documents with a variable in `$$"""…"""` strings.
- The `generateBaton` task runs `batonc generate --language kotlin` over
  the hosts into `build/generated/baton`, which the sample compiles beside
  its sources, as an app's build would.
- `Main.kt` makes the environment, `Environment(url)`, in the composition
  and provides it with `CompositionLocalProvider(LocalBaton provides …)`.

Build the compiler first (`cargo build --release` in `compiler/`), then,
from `kotlin/`:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 21) gradle :samples:desktop:run
```
