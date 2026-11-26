"""`baton_generate`: `batonc generate` with every input and output declared.
It yields the generated sources for the adopter's own library rule, the
report, the fragments file and the persisted documents file as output
groups, and `BatonInfo` for the targets that list it in `deps`."""

load(":naming.bzl", "LANGUAGES", "SOURCE_ATTRS", "TOOLCHAIN_TYPE", "outputs_by_source")
load(":providers.bzl", "BatonInfo", "bases_of")

def _baton_generate_impl(ctx):
    batonc = ctx.toolchains[TOOLCHAIN_TYPE].batonc
    language = LANGUAGES[ctx.attr.language]
    directory = ctx.label.name

    args = ctx.actions.args()
    args.add("generate")
    args.add("--config", ctx.file.config)
    args.add_all(ctx.files.schema, before_each = "--schema")
    args.add("--language", ctx.attr.language)
    shared = ctx.actions.declare_file(directory + "/" + language.shared)
    args.add("--shared", shared)
    report = ctx.actions.declare_file(directory + "/Baton.report.json")
    args.add("--report", report)

    # What a dependent reads is the fragments file and not the report: it
    # changes only when a fragment does, so an edit to one of this target's
    # operations reruns no dependent.
    fragments = ctx.actions.declare_file(directory + "/Baton.fragments.json")
    args.add("--fragments", fragments)
    if ctx.attr.module:
        args.add("--module", ctx.attr.module)
    bases = bases_of(ctx.attr.deps)
    args.add_all(bases, before_each = "--base")

    # A target at the top of an app has every target's fragments file among
    # its bases: more than a command line holds.
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    persisted = []
    if ctx.attr.persisted:
        persisted.append(ctx.actions.declare_file(directory + "/" + ctx.attr.persisted))
        args.add("--persisted", persisted[0])
    sources = []
    for src, name in outputs_by_source(ctx.files.srcs, ctx.label.package, language):
        output = ctx.actions.declare_file(directory + "/" + name)
        sources.append(output)
        args.add_joined("--emit", [src, output], join_with = "=")
    args.add_all(ctx.files.srcs)

    ctx.actions.run(
        mnemonic = "BatonGenerate",
        progress_message = "Baton: compile GraphQL in %{label}",
        executable = batonc,
        arguments = [args],
        inputs = depset(
            ctx.files.srcs + [ctx.file.config] + ctx.files.schema + ctx.files.schema_extensions,
            transitive = [bases],
        ),
        outputs = sources + [shared, report, fragments] + persisted,
    )
    return [
        DefaultInfo(files = depset(sources + [shared])),
        OutputGroupInfo(
            report = depset([report]),
            fragments = depset([fragments]),
            persisted = depset(persisted),
        ),
        BatonInfo(fragments = depset([fragments], transitive = [bases])),
    ]

baton_generate = rule(
    implementation = _baton_generate_impl,
    doc = """Runs `batonc generate` over a target's sources as one sandboxed
action: one output per source, named as the SwiftPM plugin names it, plus
the shared file. The files are the rule's default output, to list in the
`srcs` of a `swift_library` or a `kt_jvm_library`; the report, the
fragments file and, when `persisted` names it, the persisted documents file
are the output groups `report`, `fragments` and `persisted`. A target that
lists this one in `deps` spreads its fragments and reads them through the
lenses generated here.""",
    attrs = dict(SOURCE_ATTRS, **{
        "module": attr.string(
            doc = "The Swift module the generated sources are compiled in, the `module_name` of the `swift_library` that lists them. Written into the fragments file, so a target that lists this one in `deps` imports its lenses from that module; a Swift target others depend on names it. Swift only: a Kotlin target does not set it, since `batonc` refuses `--module` on a Kotlin run and its fragments file names the package of its shared file.",
        ),
    }),
    toolchains = [TOOLCHAIN_TYPE],
)
