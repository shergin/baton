# Rick and Morty, on the desktop

The public Rick and Morty API (`https://rickandmortyapi.com/graphql`)
through the Kotlin runtime, in Compose for Desktop; the Kotlin counterpart
of `examples/RickAndMorty`. The characters, a page at a time, beside the
detail of the one selected: its header, which the list fetched and the
`character` lookup finds in the store, and its episodes, which only the
detail fetches.

- The screens are `../shared`, Compose Multiplatform in common code, which
  the Android app (`../android`) shows too; this module is the window, the
  menu and the screenshots.
- `../shared/baton.json` names the schema under `spec/rickandmorty/`, the
  lookups, and the package of the shared file.
- The hosts are the shared module's `.kt` files: `@Fragment` on the
  composable that renders a lens, `@Query` on the one that resolves an
  operation value with `rememberQuery`, documents with a variable in
  `$$"""…"""` strings.
- The shared module's `generateBaton` task runs `batonc generate --language
  kotlin` over the hosts into its `build/generated/baton`, which it
  compiles beside its sources, as an app's build would.
- `Main.kt` makes the environment in the composition, over a store whose
  image lives in the user's cache directory under the schema's digest
  (`Persistence.named("RickAndMorty", version = Types.schemaDigest)`), and
  provides it with `CompositionLocalProvider(LocalBaton provides …)`; the
  second launch shows the characters before the network answers.
- The View menu's Store Inspector, or Command-I (Control-I off a Mac),
  shows `baton-inspector`'s `StoreInspector` in a third pane: the
  store's records by type, searchable, each opening onto its fields, live.
- The window follows the system's appearance with Material 3's light and
  dark color schemes; the list keys its rows by `recordID.key`.
- `Screenshot.kt` draws both screens to PNG files without a window, through
  `ImageComposeScene`, for the README and for a machine with no screen:
  `gradle :samples:desktop:screenshot` writes `build/screenshots/`, the
  inspector's pane among them.

The public API rate-limits a burst (HTTP 429, Cloudflare's code 1015): a
page the API refused shows the failure under the page bar with a retry,
and avatars are fetched once per address and kept for the process.

Build the compiler first (`cargo build --release` in `compiler/`), then,
from `kotlin/`:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 21) gradle :samples:desktop:run
```
