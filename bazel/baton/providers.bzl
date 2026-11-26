"""What a `baton_generate` hands the targets that list it in `deps`."""

BatonInfo = provider(
    doc = "A target's fragments, for the targets that spread them: its bases, in Relay's word.",
    fields = {
        "fragments": "A depset of the fragments files of the target and of every target it depends on, each the head and the fragments of a report: what `batonc generate --base` reads.",
    },
)

def bases_of(deps):
    """The fragments files of `deps` and of all they depend on: the closure
    a compilation is given, since an operation's text prints every fragment
    it reaches, however deep its base."""
    return depset(transitive = [dep[BatonInfo].fragments for dep in deps])
