"""`baton_check_test`: `batonc generate --check` over committed output, for
a team that commits its generated code and gates on its freshness."""

load(":naming.bzl", "LANGUAGES", "SOURCE_ATTRS", "TOOLCHAIN_TYPE", "outputs_by_source")

def _quoted(path):
    return "'" + path.replace("'", "'\\''") + "'"

def _baton_check_test_impl(ctx):
    batonc = ctx.toolchains[TOOLCHAIN_TYPE].batonc
    language = LANGUAGES[ctx.attr.language]
    package = ctx.label.package
    directory = (package + "/" if package else "") + ctx.attr.generated_dir

    arguments = [
        "generate",
        "--config",
        ctx.file.config.short_path,
        "--schema",
        ctx.file.schema.short_path,
        "--language",
        ctx.attr.language,
        "--shared",
        directory + "/" + language.shared,
    ]
    if ctx.attr.persisted:
        arguments += ["--persisted", directory + "/" + ctx.attr.persisted]
    for src, name in outputs_by_source(ctx.files.srcs, package, language):
        arguments += ["--emit", src.short_path + "=" + directory + "/" + name]
    arguments.append("--check")
    arguments += [src.short_path for src in ctx.files.srcs]

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "#!/bin/sh\nset -eu\ncd \"$TEST_SRCDIR\"/{workspace}\nexec {batonc} {arguments}\n".format(
            workspace = _quoted(ctx.workspace_name),
            batonc = _quoted(batonc.short_path),
            arguments = " ".join([_quoted(argument) for argument in arguments]),
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = ctx.files.srcs + ctx.files.generated + ctx.files.schema_extensions +
                [ctx.file.config, ctx.file.schema, batonc],
    )
    return [DefaultInfo(executable = script, runfiles = runfiles)]

baton_check_test = rule(
    implementation = _baton_check_test_impl,
    doc = """Runs `batonc generate --check` over the committed outputs under
`generated_dir`, the same inputs as a `baton_generate`, and fails naming
each output that is stale or missing. For a team that commits generated
code: `generate` as a developer step, this test in CI.""",
    attrs = dict(SOURCE_ATTRS, **{
        "generated": attr.label_list(
            doc = "The committed outputs, usually `glob([\"Generated/*\"])`.",
            allow_files = True,
        ),
        "generated_dir": attr.string(
            doc = "The directory the committed outputs are in, relative to the package.",
            default = "Generated",
        ),
    }),
    test = True,
    toolchains = [TOOLCHAIN_TYPE],
)
