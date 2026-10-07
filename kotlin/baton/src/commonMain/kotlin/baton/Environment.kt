package baton

/**
 * The environment: the store, the transports and the log one app session
 * runs on, which fetches for the lenses an owner scopes and heals what they
 * find missing. Defined with the environment; an owner keeps its reference.
 * See `spec/runtime.md`, section 10.
 */
internal class Environment
