/**
 * A jest setup file that records what Relay's own store tests feed its
 * normalizer, its availability check, its reader and its reference marker,
 * for `translate.py` to turn into Baton spec cases. It is run from a
 * checkout of Relay whose dependencies are installed and whose `dist/` is
 * built (`yarn install --ignore-scripts`, then `gulp dist`):
 *
 *   HARVEST_OUT=/path/to/out NODE_ENV=test OSS=true node_modules/.bin/jest \
 *     packages/relay-runtime/store/__tests__/<Suite>-test.js \
 *     --setupFilesAfterEnv /path/to/record.js
 *
 * Each call appends one JSON line to `$HARVEST_OUT/<test file>.jsonl`. A
 * `normalize` line holds the test's name, the operation's name and the text
 * of its compiled artifact, the variables, the payload and its errors, the
 * options, the feature flags that differ from their defaults, and the record
 * source before and after the call. A `check`, `read` or `mark` line holds
 * the store the test seeded by hand and Relay's answer on it.
 *
 * Baton's cases start from a response, never from a seeded store, so for a
 * query's selector at the root the line also holds a response synthesized
 * from the seeded store: the selection walked over its records, a field the
 * store lacks left out of the response, a field error written as a response
 * error. Relay then normalizes that response into an empty store and answers
 * again; the line holds that answer too, and the translator keeps a test only
 * when the two agree, so that the case compares Baton and Relay on one
 * response a server could send.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const out = process.env.HARVEST_OUT;
const runtime = path.join(process.cwd(), 'packages/relay-runtime');
const store = path.join(runtime, 'store');
const generated = path.join(store, '__tests__/__generated__');

const normalizer = require(path.join(store, 'RelayResponseNormalizer'));
const checker = require(path.join(store, 'DataChecker'));
const reader = require(path.join(store, 'RelayReader'));
const marker = require(path.join(store, 'RelayReferenceMarker'));
const RelayRecordSource = require(path.join(store, 'RelayRecordSource'));
const RelayModernRecord = require(path.join(store, 'RelayModernRecord'));
const {getStorageKey, ROOT_ID, ROOT_TYPE} = require(path.join(store, 'RelayStoreUtils'));
const {generateTypeID} = require(path.join(store, 'TypeID'));
const defaultGetDataID = require(path.join(store, 'defaultGetDataID'));
const RelayFeatureFlags = require(path.join(runtime, 'util/RelayFeatureFlags'));

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

function artifact(name) {
  const file = path.join(generated, name + '.graphql.js');
  return fs.existsSync(file) ? require(file) : null;
}

function artifactText(name) {
  const found = artifact(name);
  return found && found.params ? found.params.text : null;
}

/** A value as JSON: a set as a sorted list, a fragment's owner as its identifier. */
function snapshot(value) {
  if (value === undefined) {
    return null;
  }
  return JSON.parse(
    JSON.stringify(value, (key, item) => {
      if (key === '__fragmentOwner' && item != null) {
        return item.identifier;
      }
      if (item instanceof Set) {
        return Array.from(item).sort();
      }
      if (typeof item === 'function') {
        return undefined;
      }
      return item;
    }),
  );
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

// MARK: The response a seeded store stands for

/** An error saying why a seeded store stands for no response. */
function Unsynthesizable(message) {
  return new Error(message);
}

/**
 * The response a server would have sent for `node`'s selections to leave
 * what `source` holds under the root, and its errors.
 */
function synthesize(source, node, variables) {
  const errors = [];
  const typeRecord = record =>
    source.get(generateTypeID(RelayModernRecord.getType(record)));

  function object(selections, record, here) {
    const result = {};
    const type = RelayModernRecord.getType(record);
    if (type != null && type !== ROOT_TYPE) {
      result.__typename = type;
    }
    walk(selections, record, result, here);
    return result;
  }

  function fieldErrors(record, storageKey, here) {
    const all = record.__errors && record.__errors[storageKey];
    for (const error of all || []) {
      const entry = Object.assign({}, error, {path: here.concat(error.path || [])});
      errors.push(entry);
    }
  }

  function linked(record, field, value, here) {
    if (value == null || typeof value !== 'object') {
      return value;
    }
    const child = id => {
      const found = source.get(id);
      if (found === undefined) {
        throw new Unsynthesizable('a link to a record the store does not hold');
      }
      if (found === null) {
        throw new Unsynthesizable('a link to a deleted record');
      }
      return found;
    };
    if (value.__ref !== undefined) {
      return object(field.selections, child(value.__ref), here);
    }
    if (value.__refs !== undefined) {
      return value.__refs.map((id, index) =>
        id == null ? null : object(field.selections, child(id), here.concat([index])),
      );
    }
    throw new Unsynthesizable('a linked field holding a scalar');
  }

  function walk(selections, record, result, here) {
    for (const selection of selections) {
      switch (selection.kind) {
        case 'ScalarField':
        case 'LinkedField': {
          const storageKey = getStorageKey(selection, variables);
          const responseKey = selection.alias || selection.name;
          const value = record[storageKey];
          if (value === undefined) {
            break;
          }
          const at = here.concat([responseKey]);
          result[responseKey] =
            selection.kind === 'ScalarField' ? value : linked(record, selection, value, at);
          fieldErrors(record, storageKey, at);
          break;
        }
        case 'InlineFragment': {
          const type = RelayModernRecord.getType(record);
          if (selection.abstractKey == null) {
            if (type === selection.type || type === ROOT_TYPE) {
              walk(selection.selections, record, result, here);
            }
            break;
          }
          const types = typeRecord(record);
          if (types && types[selection.abstractKey] === true) {
            result[selection.abstractKey] = type;
            walk(selection.selections, record, result, here);
          }
          break;
        }
        case 'TypeDiscriminator': {
          const types = typeRecord(record);
          if (types && types[selection.abstractKey] === true) {
            result[selection.abstractKey] = RelayModernRecord.getType(record);
          }
          break;
        }
        case 'Condition':
          if (Boolean(variables[selection.condition]) === selection.passingValue) {
            walk(selection.selections, record, result, here);
          }
          break;
        case 'Defer':
        case 'Stream':
        case 'ClientExtension':
          walk(selection.selections, record, result, here);
          break;
        case 'LinkedHandle':
        case 'ScalarHandle':
          break;
        default:
          throw new Unsynthesizable('a `' + selection.kind + '` selection');
      }
    }
  }

  const root = source.get(ROOT_ID);
  if (root == null) {
    throw new Unsynthesizable('no root record');
  }
  return {data: object(node.selections, root, []), errors};
}

/**
 * The response `source` stands for under a query at the root, the store
 * Relay normalizes from it, or why there is none.
 */
function responseFor(source, operation, variables) {
  try {
    const response = synthesize(source, operation, variables);
    const normalized = new RelayRecordSource();
    normalized.set(ROOT_ID, RelayModernRecord.create(ROOT_ID, ROOT_TYPE));
    normalize(
      normalized,
      {dataID: ROOT_ID, node: operation, variables},
      response.data,
      {getDataID: defaultGetDataID, treatMissingFieldsAsNull: false, deferDeduplicatedFields: false, log: null},
      response.errors.length ? response.errors : undefined,
    );
    return {response, normalized};
  } catch (error) {
    return {unsynthesizable: String(error && error.message)};
  }
}

/** The request a selector's node belongs to, when it is a query's. */
function requestOf(node) {
  const found = node && node.name ? artifact(node.name) : null;
  return found && found.kind === 'Request' && found.params.operationKind === 'query' ? found : null;
}

function common(selector, operationName) {
  return {
    operation: operationName,
    kind: selector.node.kind,
    text: artifactText(operationName),
    dataID: selector.dataID,
    variables: snapshot(selector.variables),
    flags: changedFlags(),
  };
}

// MARK: The wrapped calls

const normalize = normalizer.normalize;
normalizer.normalize = function (recordSource, selector, response, options, errors, useExecTimeResolvers) {
  const before = snapshot(recordSource.toJSON());
  const payload = snapshot(response);
  let result;
  let thrown = null;
  try {
    result = normalize.apply(this, arguments);
  } catch (error) {
    thrown = String(error && error.message);
    throw error;
  } finally {
    write(
      Object.assign(common(selector, selector.node.name), {
        function: 'normalize',
        payload,
        errors: snapshot(errors),
        options: {
          treatMissingFieldsAsNull: !!options.treatMissingFieldsAsNull,
          deferDeduplicatedFields: !!options.deferDeduplicatedFields,
          customGetDataID: options.getDataID !== defaultGetDataID,
          useExecTimeResolvers: !!useExecTimeResolvers,
        },
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
      }),
    );
  }
  return result;
};

const check = checker.check;
checker.check = function (getSource, getTarget, actor, selector, handlers, operationLoader, getDataID) {
  const source = getSource(actor);
  const seeded = snapshot(source.toJSON());
  const answer = check.apply(this, arguments);
  const line = Object.assign(common(selector, selector.node.name), {
    function: 'check',
    seeded,
    handlers: handlers.length,
    customGetDataID: getDataID !== defaultGetDataID,
    answer: snapshot(answer),
  });
  const request = requestOf(selector.node);
  if (selector.dataID === ROOT_ID && request) {
    const made = responseFor(source, request.operation, selector.variables);
    Object.assign(line, made.unsynthesizable ? {unsynthesizable: made.unsynthesizable} : {response: made.response});
    if (made.normalized) {
      line.normalized = snapshot(made.normalized.toJSON());
      const args = Array.from(arguments);
      args[0] = () => made.normalized;
      args[1] = () => new RelayRecordSource();
      line.answerFromResponse = snapshot(check.apply(this, args));
    }
  }
  write(line);
  return answer;
};

const read = reader.read;
reader.read = function (recordSource, selector) {
  const answer = read.apply(this, arguments);
  const visible = value => ({
    data: snapshot(value.data),
    isMissingData: value.isMissingData,
    fieldErrors: snapshot(value.fieldErrors),
  });
  const line = Object.assign(common(selector, selector.node.name), {
    function: 'read',
    seeded: snapshot(recordSource.toJSON()),
    answer: visible(answer),
  });
  const request = requestOf(selector.node);
  if (selector.dataID === ROOT_ID && request) {
    const made = responseFor(recordSource, request.operation, selector.variables);
    Object.assign(line, made.unsynthesizable ? {unsynthesizable: made.unsynthesizable} : {response: made.response});
    if (made.normalized) {
      line.normalized = snapshot(made.normalized.toJSON());
      const args = Array.from(arguments);
      args[0] = made.normalized;
      line.answerFromResponse = visible(read.apply(this, args));
    }
  }
  write(line);
  return answer;
};

const mark = marker.mark;
marker.mark = function (recordSource, selector, references) {
  const seeded = snapshot(recordSource.toJSON());
  const before = new Set(references);
  const result = mark.apply(this, arguments);
  const added = Array.from(references).filter(id => !before.has(id)).sort();
  const line = Object.assign(common(selector, selector.node.name), {
    function: 'mark',
    seeded,
    answer: added,
  });
  const request = requestOf({name: selector.node.name});
  if (selector.dataID === ROOT_ID && request) {
    const made = responseFor(recordSource, request.operation, selector.variables);
    Object.assign(line, made.unsynthesizable ? {unsynthesizable: made.unsynthesizable} : {response: made.response});
    if (made.normalized) {
      line.normalized = snapshot(made.normalized.toJSON());
      const marked = new Set();
      const args = Array.from(arguments);
      args[0] = made.normalized;
      args[2] = marked;
      mark.apply(this, args);
      line.answerFromResponse = Array.from(marked).sort();
    }
  }
  write(line);
  return result;
};
