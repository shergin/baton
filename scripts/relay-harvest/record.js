/**
 * A jest setup file that records what Relay's own store tests feed its
 * normalizer, for `translate.py` to turn into Baton spec cases. It is run
 * from a checkout of Relay whose dependencies are installed and whose
 * `dist/` is built (`yarn install --ignore-scripts`, then `gulp dist`):
 *
 *   HARVEST_OUT=/path/to/out NODE_ENV=test OSS=true node_modules/.bin/jest \
 *     --setupFilesAfterEnv /path/to/record.js \
 *     packages/relay-runtime/store/__tests__/RelayResponseNormalizer-test.js
 *
 * Each call of `normalize` appends one JSON line to
 * `$HARVEST_OUT/<test file>.jsonl`: the test's name, the operation's name
 * and the text of its compiled artifact, the variables, the payload and its
 * errors, the options, the feature flags that differ from their defaults,
 * and the record source before and after the call. Nothing is parsed; the
 * records are what the call saw.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const out = process.env.HARVEST_OUT;
const store = path.join(process.cwd(), 'packages/relay-runtime/store');
const generated = path.join(store, '__tests__/__generated__');

const normalizer = require(path.join(store, 'RelayResponseNormalizer'));
const defaultGetDataID = require(path.join(store, 'defaultGetDataID'));
const RelayFeatureFlags = require(
  path.join(process.cwd(), 'packages/relay-runtime/util/RelayFeatureFlags'),
);

const defaultFlags = Object.assign({}, RelayFeatureFlags);
const calls = new Map();

function changedFlags() {
  const changed = {};
  for (const key of Object.keys(RelayFeatureFlags)) {
    if (RelayFeatureFlags[key] !== defaultFlags[key]) {
      changed[key] =
        typeof RelayFeatureFlags[key] === 'function'
          ? String(RelayFeatureFlags[key])
          : RelayFeatureFlags[key];
    }
  }
  return changed;
}

function artifactText(name) {
  const file = path.join(generated, name + '.graphql.js');
  if (!fs.existsSync(file)) {
    return null;
  }
  const artifact = require(file);
  return artifact && artifact.params ? artifact.params.text : null;
}

function snapshot(value) {
  return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

function write(record) {
  if (!out) {
    return;
  }
  const state = expect.getState();
  const test = state.currentTestName;
  const index = calls.get(test) || 0;
  calls.set(test, index + 1);
  const line = Object.assign(
    {test, call: index, file: path.basename(state.testPath)},
    record,
  );
  fs.mkdirSync(out, {recursive: true});
  fs.appendFileSync(
    path.join(out, path.basename(state.testPath, '.js') + '.jsonl'),
    JSON.stringify(line) + '\n',
  );
}

const normalize = normalizer.normalize;
normalizer.normalize = function (recordSource, selector, response, options, errors, useExecTimeResolvers) {
  const before = snapshot(recordSource.toJSON());
  const payload = snapshot(response);
  const node = selector.node;
  let result;
  let thrown = null;
  try {
    result = normalize.apply(this, arguments);
  } catch (error) {
    thrown = String(error && error.message);
    throw error;
  } finally {
    write({
      function: 'normalize',
      operation: node.name,
      kind: node.kind,
      text: artifactText(node.name),
      dataID: selector.dataID,
      variables: snapshot(selector.variables),
      payload,
      errors: snapshot(errors),
      options: {
        treatMissingFieldsAsNull: !!options.treatMissingFieldsAsNull,
        deferDeduplicatedFields: !!options.deferDeduplicatedFields,
        customGetDataID: options.getDataID !== defaultGetDataID,
        useExecTimeResolvers: !!useExecTimeResolvers,
      },
      flags: changedFlags(),
      before,
      after: snapshot(recordSource.toJSON()),
      result: result
        ? {
            followupPayloads: result.followupPayloads.length,
            incrementalPlaceholders: result.incrementalPlaceholders.length,
            fieldPayloads: result.fieldPayloads.length,
          }
        : null,
      thrown,
    });
  }
  return result;
};
