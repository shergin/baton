"""What the languages share: the output each source writes, named by the
rule the SwiftPM plugin and `batonc generate --out` use."""

# The source extension, the output suffix and the shared file, by language.
LANGUAGES = {
    "swift": struct(extension = ".swift", suffix = ".baton.swift", shared = "Baton.baton.swift"),
    "kotlin": struct(extension = ".kt", suffix = ".baton.kt", shared = "Baton.baton.kt"),
}

TOOLCHAIN_TYPE = Label("//baton:toolchain_type")

def output_name(src, package, language):
    """The name of the output `src` writes: its path relative to the rule's
    package, or to its own repository's root when it comes from another,
    each separator an underscore, with the language's suffix in place of
    its own extension and after any other, so `Thing.swift` and
    `Thing.graphql` write two outputs."""
    path = src.short_path
    if path.startswith("../"):
        path = path.split("/", 2)[2]
    elif package and path.startswith(package + "/"):
        path = path[len(package) + 1:]
    extension = language.extension
    stem = path[:-len(extension)] if path.endswith(extension) else path
    return stem.replace("/", "_") + language.suffix

def outputs_by_source(srcs, package, language):
    """Each source with its output's name, refusing two that would write one
    file and a source that would write the shared file, as the compiler
    refuses them."""
    named = {}
    pairs = []
    for src in srcs:
        name = output_name(src, package, language)
        if name == language.shared:
            fail("`{}` would write the shared `{}`; rename it".format(src.short_path, name))
        if name in named:
            fail("`{}` and `{}` would both write `{}`; rename one".format(named[name].short_path, src.short_path, name))
        named[name] = src
        pairs.append((src, name))
    return pairs

SOURCE_ATTRS = {
    "srcs": attr.label_list(
        doc = "The target's host sources, Swift or Kotlin, and its `.graphql` documents; every one gets an output.",
        allow_files = [".swift", ".kt", ".graphql", ".gql"],
        mandatory = True,
    ),
    "config": attr.label(
        doc = "The target's `baton.json`.",
        allow_single_file = [".json"],
        mandatory = True,
    ),
    "schema": attr.label(
        doc = "The schema SDL, passed as `--schema`, so it may be a build's own output.",
        allow_single_file = True,
        mandatory = True,
    ),
    "schema_extensions": attr.label_list(
        doc = "The client schema extensions `baton.json` names, declared so the sandbox holds them.",
        allow_files = True,
    ),
    "language": attr.string(
        doc = "The language the run writes.",
        default = "swift",
        values = ["swift", "kotlin"],
    ),
    "persisted": attr.string(
        doc = "The name of the persisted documents file to write under `persistConfig`; none when unset.",
    ),
}
