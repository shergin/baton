"""The compiler as a toolchain: one `batonc` binary, which the extension
declares once per variant of the bundle."""

def _baton_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        batonc = ctx.executable.batonc,
    )]

baton_toolchain = rule(
    implementation = _baton_toolchain_impl,
    doc = "The `batonc` binary the rules run.",
    attrs = {
        "batonc": attr.label(
            doc = "The compiler binary.",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
    },
)
