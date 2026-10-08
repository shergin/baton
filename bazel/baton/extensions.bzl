"""The module extension that fetches the compiler: the release's artifact
bundle, the one file SwiftPM downloads, read as SwiftPM reads it; or, when
`BATON_COMPILER` names one, a checkout's own compiler, as it does for
`Package.swift`. Set it with `--repo_env=BATON_COMPILER=<path>` to a built
`batonc` or to a bundle directory holding an `info.json`."""

load(":release.bzl", "BUNDLE_SHA256", "VERSION")

_TOOLCHAIN_RULE = str(Label("//baton:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//baton:toolchain_type"))

# The triples a bundle lists, as SwiftPM spells them, and the platform each
# names. A Linux binary is static, so the bundle lists it under the gnu
# triple a Linux host reports.
_TRIPLES = {
    "arm64-apple-macosx": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "x86_64-apple-macosx": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "x86_64-unknown-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "aarch64-unknown-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
}

def _toolchain_text(name, path, constraints):
    return """
baton_toolchain(
    name = "{name}_impl",
    batonc = "{path}",
)

toolchain(
    name = "{name}",
    exec_compatible_with = {constraints},
    toolchain = ":{name}_impl",
    toolchain_type = "{toolchain_type}",
)
""".format(
        name = name,
        path = path,
        constraints = repr(constraints),
        toolchain_type = _TOOLCHAIN_TYPE,
    )

def _build_text(toolchains):
    text = """load("{rule}", "baton_toolchain")

package(default_visibility = ["//visibility:public"])
""".format(rule = _TOOLCHAIN_RULE)
    for name, path, constraints in toolchains:
        text += _toolchain_text(name, path, constraints)
    return text

def _bundle_toolchains(info, prefix):
    """One toolchain per triple of each variant an `info.json` lists."""
    toolchains = []
    for variant in info["artifacts"]["batonc"]["variants"]:
        for triple in variant["supportedTriples"]:
            constraints = _TRIPLES.get(triple)
            if constraints == None:
                fail("the bundle lists `{}`, a triple rules_baton does not know".format(triple))
            toolchains.append((triple.replace("-", "_"), prefix + variant["path"], constraints))
    return toolchains

def _local(rctx, named):
    path = rctx.path(named)
    if not path.exists:
        fail("BATON_COMPILER names `{}`, which does not exist".format(named))
    if path.get_child("info.json").exists:
        rctx.symlink(path, "bundle")
        info = json.decode(rctx.read(path.get_child("info.json")))
        return _bundle_toolchains(info, "bundle/")

    # One binary, built where the build runs: a toolchain for every platform.
    rctx.symlink(path, "batonc")
    return [("local", "batonc", [])]

def _batonc_impl(rctx):
    named = rctx.getenv("BATON_COMPILER")
    if named:
        toolchains = _local(rctx, named)
    else:
        rctx.download_and_extract(
            url = "https://github.com/shergin/baton/releases/download/v{}/batonc.artifactbundle.zip".format(rctx.attr.version),
            sha256 = rctx.attr.sha256,
            stripPrefix = "batonc.artifactbundle",
        )
        toolchains = _bundle_toolchains(json.decode(rctx.read("info.json")), "")
    rctx.file("BUILD.bazel", _build_text(toolchains))

_batonc = repository_rule(
    implementation = _batonc_impl,
    doc = "The compiler bundle of one release, with a toolchain per variant.",
    attrs = {
        "version": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
    },
)

def _baton_impl(_module_ctx):
    _batonc(
        name = "batonc",
        version = VERSION,
        sha256 = BUNDLE_SHA256,
    )

baton = module_extension(
    implementation = _baton_impl,
    doc = "Fetches the compiler bundle of the release this module is versioned with.",
)
