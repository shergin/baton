"""The public rules of rules_baton."""

load(":check.bzl", _baton_check_test = "baton_check_test")
load(":generate.bzl", _baton_generate = "baton_generate")
load(":providers.bzl", _BatonInfo = "BatonInfo")

baton_generate = _baton_generate

# What a `baton_generate` hands the targets that list it in `deps`, for an
# adopter's own rule that stands between two of them.
BatonInfo = _BatonInfo

def baton_check_test(name, size = "small", **kwargs):
    """`baton_check_test`, small by default: one compiler run."""
    _baton_check_test(name = name, size = size, **kwargs)
