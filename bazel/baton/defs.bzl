"""The public rules of rules_baton."""

load(":check.bzl", _baton_check_test = "baton_check_test")
load(":generate.bzl", _baton_generate = "baton_generate")

baton_generate = _baton_generate

def baton_check_test(name, size = "small", **kwargs):
    """`baton_check_test`, small by default: one compiler run."""
    _baton_check_test(name = name, size = size, **kwargs)
