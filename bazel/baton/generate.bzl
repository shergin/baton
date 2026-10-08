"""`baton_generate`: `batonc generate` with every input and output declared.
It yields the generated sources for the adopter's own library rule, and the
report and the persisted documents file as output groups."""

load(":naming.bzl", "LANGUAGES", "SOURCE_ATTRS", "TOOLCHAIN_TYPE", "outputs_by_source")

def _baton_generate_impl(ctx):
    batonc = ctx.toolchains[TOOLCHAIN_TYPE].batonc
    language = LANGUAGES[ctx.attr.language]
    directory = ctx.label.name

    args = ctx.actions.args()
    args.add("generate")
    args.add("--config", ctx.file.config)
    args.add("--schema", ctx.file.schema)
    args.add("--language", ctx.attr.language)
    shared = ctx.actions.declare_file(directory + "/" + language.shared)
    args.add("--shared", shared)
    report = ctx.actions.declare_file(directory + "/Baton.report.json")
    args.add("--report", report)
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
        inputs = ctx.files.srcs + [ctx.file.config, ctx.file.schema] + ctx.files.schema_extensions,
        outputs = sources + [shared, report] + persisted,
    )
    return [
        DefaultInfo(files = depset(sources + [shared])),
        OutputGroupInfo(
            report = depset([report]),
            persisted = depset(persisted),
        ),
    ]

baton_generate = rule(
    implementation = _baton_generate_impl,
    doc = """Runs `batonc generate` over a target's sources as one sandboxed
action: one output per source, named as the SwiftPM plugin names it, plus
the shared file. The files are the rule's default output, to list in the
`srcs` of a `swift_library` or a `kt_jvm_library`; the report and, when
`persisted` names it, the persisted documents file are the output groups
`report` and `persisted`.""",
    attrs = SOURCE_ATTRS,
    toolchains = [TOOLCHAIN_TYPE],
)
