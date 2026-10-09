#!/usr/bin/env python3
"""Turns what `record.js` recorded from Relay's store tests into Baton spec
cases under `spec/relay/`.

    python3 scripts/relay-harvest/translate.py \
        --relay <Relay checkout> --harvest <HARVEST_OUT> \
        --batonc compiler/target/release/batonc

Relay keys a record by its raw id (`1`) or by a client id that chains the
parent's id and the field (`client:1:friends(first:3)`), types its root
`__Root`, and stores the key again as `__id`. Baton keys an entity by its type
and id (`User:1`), keys an object without one by its parent's Baton key and
the field, adding the concrete type under an interface or union, types its
root `Query`, and dumps the empty mutation and subscription roots. The
translation renames the keys by walking the links from the root and writes
one record a line, keys sorted, as the Swift runtime's `StoreExport` does.
Relay's `client:__type:` records, its note of which abstract types a type
implements, are left out; Baton keeps memberships outside the records.
Nothing else is changed: a value Relay stores is the value the dump holds.
In the documents, Relay's `@dangerously_unaliased_fixme`, which silences the
check that a conditional spread is aliased, becomes `@alias`; neither
changes what is normalized.

Relay's tests are measured against, not obeyed, so each test gets a
status. A test that depends on something Baton has no counterpart of (a
custom `getDataID`, a feature flag, `treatMissingFieldsAsNull`, a document
batonc rejects) is ingested as `unsupported-feature` and left out of the
runs; its document goes to `unsupported/`. A test the harvest cannot express
yet (a store seeded by hand, one id given objects of several types, a client
id that cannot be traced to its parent) is `not-ingested`. A kept test named
in `expectations.json` beside this file takes the status, note and decision
written there: `possible-bug`, `unspecified-behaviour`, `invalid-input` or
`by-design`, each run with its result ignored. The rest must pass. Cases
are one `normalize` call; scripts of `payload` steps are several in a row.
A client extension file batonc rejects is left out of the schema, and the
tests that need it become unsupported with batonc's reason.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = os.path.join(ROOT, 'spec')
OUT = os.path.join(SPEC, 'relay')
SWIFT = os.path.join(ROOT, 'swift', 'Tests', 'BatonRelayTests')
MUTATION_ROOT = 'client:root:mutation'
SUBSCRIPTION_ROOT = 'client:root:subscription'

# The test files harvested, by the directory each one's cases go to.
SUITES = {
    'RelayResponseNormalizer-test': 'normalizer',
}


# MARK: The schema


def schema_types(paths):
    """Each composite type's kind and fields' named types, from SDL files.
    Only what the key translation needs: whether a field's type is abstract."""
    kinds = {}
    fields = {}
    for path in paths:
        text = open(path).read()
        text = re.sub(r'"""[\s\S]*?"""', '', text)
        text = re.sub(r'"[^"\n]*"', '""', text)
        text = re.sub(r'#[^\n]*', '', text)
        for match in re.finditer(r'(extend\s+)?(type|interface|union|input|enum|scalar)\s+(\w+)', text):
            kind, name = match.group(2), match.group(3)
            if not match.group(1):
                kinds[name] = kind
            if kind not in ('type', 'interface', 'input'):
                continue
            start = text.find('{', match.end())
            if start < 0 or text[match.end():start].count('\n') > 3 and '=' in text[match.end():start]:
                continue
            depth, index = 0, start
            body_start = start + 1
            while index < len(text):
                if text[index] in '{(':
                    depth += 1
                elif text[index] in '})':
                    depth -= 1
                    if depth == 0:
                        break
                index += 1
            body = text[body_start:index]
            body = strip_parentheses(body)
            for field in re.finditer(r'(\w+)\s*:\s*\[*\s*(\w+)', body):
                fields.setdefault(name, {})[field.group(1)] = field.group(2)
    return kinds, fields


def strip_parentheses(text):
    out, depth = [], 0
    for character in text:
        if character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
        elif depth == 0:
            out.append(character)
    return ''.join(out)


# MARK: Documents


def documents_in(test_source):
    """Every definition inside a graphql`` template of a test file, by name:
    the text as the test's author wrote it, indentation removed."""
    definitions = {}
    for template in re.finditer(r'graphql`([\s\S]*?)`', test_source):
        text = template.group(1)
        for definition in split_definitions(text):
            match = re.match(r'\s*(query|mutation|subscription|fragment)\s+(\w+)', definition)
            if match:
                definitions[match.group(2)] = dedent(definition.replace('@dangerously_unaliased_fixme', '@alias'))
    return definitions


def split_definitions(text):
    parts, depth, start = [], 0, 0
    for index, character in enumerate(text):
        if character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                parts.append(text[start:index + 1])
                start = index + 1
    return parts


def dedent(text):
    return textwrap.dedent(text.strip('\n')).rstrip() + '\n'


def with_fragments(name, definitions):
    """The operation and every fragment it spreads, transitively, in order of
    first use."""
    order, pending = [], [name]
    while pending:
        current = pending.pop(0)
        if current in order or current not in definitions:
            continue
        order.append(current)
        pending.extend(re.findall(r'\.\.\.\s*(\w+)', definitions[current]))
    return order


# MARK: Keys


def client_id(parent, storage_key, index=None):
    """Relay's `generateClientID`."""
    key = parent + ':' + storage_key
    if index is not None:
        key += ':' + str(index)
    return key if key.startswith('client:') else 'client:' + key


class Untranslatable(Exception):
    pass


def translate_dump(relay, kinds, fields):
    """Relay's `recordSource.toJSON()` as Baton's dump, as a dict."""
    # Relay's records of which abstract types a concrete type implements
    # are its own bookkeeping; Baton keeps memberships outside the records.
    relay = {key: record for key, record in relay.items() if not key.startswith('client:__type:')}
    mapping = {}
    for key, record in relay.items():
        if key == 'client:root':
            mapping[key] = 'client:root'
        elif record is not None and record.get('id') == key:
            mapping[key] = '%s:%s' % (record['__typename'], key)
        elif not key.startswith('client:'):
            if record is None:
                raise Untranslatable('a deleted entity record `%s` has no type to key it by' % key)
            mapping[key] = '%s:%s' % (record['__typename'], key)

    def parent_type(record):
        type_name = record.get('__typename')
        return 'Query' if type_name == '__Root' else type_name

    def child_key(parent_key, parent_record, storage_key, child, index):
        field_name = storage_key.split('(')[0]
        field_type = fields.get(parent_type(parent_record), {}).get(field_name)
        key = mapping[parent_key] + ':' + storage_key
        if index is not None:
            key += ':' + str(index)
        if kinds.get(field_type) in ('interface', 'union'):
            key += ':' + relay[child]['__typename']
        return key

    pending = [key for key in relay if key in mapping]
    while pending:
        parent_key = pending.pop(0)
        parent_record = relay[parent_key]
        if parent_record is None:
            continue
        for storage_key, value in sorted(parent_record.items()):
            if not isinstance(value, dict):
                continue
            links = []
            if '__ref' in value:
                links = [(value['__ref'], None)]
            elif '__refs' in value:
                links = [(child, index) for index, child in enumerate(value['__refs']) if child is not None]
            for child, index in links:
                if child in mapping or not child.startswith('client:') or child not in relay:
                    continue
                if child != client_id(parent_key, storage_key, index):
                    raise Untranslatable('`%s` is not the client id of `%s` under `%s`' % (child, storage_key, parent_key))
                mapping[child] = child_key(parent_key, parent_record, storage_key, child, index)
                pending.append(child)

    unmapped = sorted(set(relay) - set(mapping))
    if unmapped:
        raise Untranslatable('no link reaches %s' % ', '.join('`%s`' % key for key in unmapped))

    def value_of(value):
        if isinstance(value, dict) and '__ref' in value:
            return {'__ref': mapping.get(value['__ref'], value['__ref'])}
        if isinstance(value, dict) and '__refs' in value:
            return {'__refs': [mapping.get(child, child) if child is not None else None for child in value['__refs']]}
        return value

    dump = {}
    for key, record in relay.items():
        if record is None:
            dump[mapping[key]] = None
            continue
        translated = {}
        for field, value in record.items():
            if field == '__id':
                continue
            if field == '__typename' and value == '__Root':
                value = 'Query'
            translated[field] = value_of(value)
        dump[mapping[key]] = translated
    dump.setdefault(MUTATION_ROOT, {'__typename': 'Mutation'})
    dump.setdefault(SUBSCRIPTION_ROOT, {'__typename': 'Subscription'})
    return dump


def dump_text(dump):
    """One record a line, keys sorted, as `StoreExport` writes a store."""
    lines = []
    for key in sorted(dump):
        record = dump[key]
        value = 'null' if record is None else json.dumps(record, sort_keys=True, ensure_ascii=False)
        lines.append('  %s: %s' % (json.dumps(key, ensure_ascii=False), value))
    return '{\n' + ',\n'.join(lines) + '\n}\n'


# MARK: The harvest


def slug(test):
    words = re.sub(r'[^a-z0-9]+', '-', test.lower()).strip('-')
    for prefix in ('relayresponsenormalizer-',):
        if words.startswith(prefix):
            words = words[len(prefix):]
    return words


def seeded(before):
    """Whether a store holds more than the empty root before the first call."""
    for key, record in before.items():
        if key != 'client:root':
            return True
        if set(record) - {'__id', '__typename'}:
            return True
    return False


def reason_outside_concepts(calls):
    """Why a test's calls are not a plain Baton case, as a status and a
    reason: `unsupported-feature` for what Baton has no counterpart of, the
    case still ingested and left out of the runs; `not-ingested` for what
    the translation or the harness cannot express yet."""
    for call in calls:
        if call['options']['customGetDataID']:
            return 'unsupported-feature', 'a custom `getDataID`: Baton keys by configured fields, not by a function'
        if call['flags']:
            return 'unsupported-feature', 'a Relay feature flag: %s' % ', '.join('`%s`' % flag for flag in sorted(call['flags']))
        if call['options']['treatMissingFieldsAsNull']:
            return 'unsupported-feature', '`treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null'
        if call['options']['useExecTimeResolvers']:
            return 'unsupported-feature', 'exec-time resolvers'
        if call['dataID'] != 'client:root':
            return 'not-ingested', 'normalized under `%s`, not the root' % call['dataID']
        if call['thrown']:
            return 'not-ingested', 'Relay throws: %s' % call['thrown']
    for call in calls:
        merged = ids_of_several_types(call['payload'])
        if merged:
            return 'not-ingested', ('one id of several types (%s): Relay merges them into one record, Baton keys by type '
                                    '(docs/decisions/identity-is-configured.md)' % ', '.join('`%s`' % id for id in merged))
    if seeded(calls[0]['before']):
        return 'not-ingested', 'a store seeded by hand before the first payload'
    for previous, call in zip(calls, calls[1:]):
        if previous['after'] != call['before']:
            return 'not-ingested', 'a store edited by hand between payloads'
    return None, None


def ids_of_several_types(payload):
    """The ids a payload gives objects of more than one type: Relay merges
    them into one record, which Baton's keys, typed, cannot name."""
    types = {}

    def walk(value):
        if isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            if isinstance(value.get('id'), str) and value.get('__typename'):
                types.setdefault(value['id'], set()).add(value['__typename'])
            for item in value.values():
                walk(item)

    walk(payload)
    return sorted(id for id, names in types.items() if len(names) > 1)


def batonc_rejection(batonc, config, text):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, 'Document.graphql')
        open(path, 'w').write(text)
        result = subprocess.run([batonc, 'validate', '--config', config, path], capture_output=True, text=True)
        if result.returncode == 0:
            return None
        lines = [line for line in (result.stderr + result.stdout).splitlines() if 'error:' in line]
        first = lines[0] if lines else (result.stderr + result.stdout).strip().splitlines()[0]
        message = first.split('error: ', 1)[-1].strip()
        return 'batonc: ' + re.sub(r'; a [\w ]+ takes .*$', '', message)


def exclude_rejected_extensions(batonc, config, directory):
    """Removes the client extension files batonc rejects, one round at a
    time, and returns each removed file with batonc's reason."""
    excluded = {}
    while True:
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, 'Document.graphql')
            open(path, 'w').write('query HarvestSchemaCheck { me { id } }\n')
            result = subprocess.run([batonc, 'validate', '--config', config, path], capture_output=True, text=True)
        rejected = {}
        for line in (result.stderr + result.stdout).splitlines():
            match = re.match(r'(.*?):\d+:\d+: error: (.*)', line)
            if match and os.path.dirname(os.path.abspath(match.group(1))) == os.path.abspath(directory):
                rejected.setdefault(os.path.basename(match.group(1)), match.group(2))
        if not rejected:
            return excluded
        for name, reason in rejected.items():
            os.remove(os.path.join(directory, name))
            excluded[name] = reason


def response_of(call):
    response = {'data': call['payload']}
    if call['errors']:
        response['errors'] = call['errors']
    return response


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as file:
        file.write(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def swift_documents(definitions, names):
    """The Swift test target's documents: every surviving operation and
    fragment, one macro each."""
    lines = [
        '// Generated by scripts/relay-harvest/translate.py from the documents of',
        "// Relay's store tests (MIT, Meta Platforms, Inc. and affiliates). Do not",
        '// edit; run the translator again.',
        '',
        'import Baton',
        '',
        '@MainActor',
        'struct RelayDocuments {',
    ]
    operations = []
    for name in names:
        text = definitions[name]
        macro = 'Fragment' if text.startswith('fragment') else 'Query'
        if text.startswith('mutation'):
            macro = 'Mutation'
        elif text.startswith('subscription'):
            macro = 'Subscription'
        if macro != 'Fragment':
            operations.append(name)
        body = '\n'.join(('        ' + line) if line else '' for line in text.rstrip('\n').split('\n'))
        lines += ['    @%s("""' % macro, body, '        """)', '    var %s: %s' % (name[0].lower() + name[1:], name), '']
    lines[-1:] = ['}', '', 'extension RelayDocuments {', '    /// Every operation by its name.', '    static let operations: [String: any Baton.Operation.Type] = [']
    lines += ['        "%s": %s.self,' % (name, name) for name in operations]
    lines += ['    ]', '}', '']
    return '\n'.join(lines)


STATUSES = [
    ('passes', 'Baton agrees with Relay; the case must pass.'),
    ('possible-bug', 'Baton is probably wrong; the case runs and its result is ignored.'),
    ('unspecified-behaviour', 'GraphQL does not say, and Relay chose; the case runs and its result is ignored.'),
    ('invalid-input', 'the payload is one a conforming server does not send; the case runs and its result is ignored.'),
    ('by-design', 'Baton parts from Relay on purpose, by a decision; the case runs and its result is ignored.'),
    ('unsupported-feature', 'Relay has something Baton does not; the case is ingested and left out of the runs.'),
    ('not-ingested', 'the harvest cannot express the test yet; nothing is written.'),
]


def write_table(table, excluded):
    """Replaces the harvest's table in `spec/relay/README.md`, between its
    markers, with each test's status."""
    path = os.path.join(OUT, 'README.md')
    text = open(path).read()
    begin, end = '<!-- harvest -->\n', '<!-- /harvest -->\n'
    counts = {}
    for row in table:
        counts[row.get('status', 'passes')] = counts.get(row.get('status', 'passes'), 0) + 1
    lines = ['%d tests harvested.' % len(table), '', '| Status | Tests | Meaning |', '|---|---|---|']
    lines += ['| `%s` | %d | %s |' % (status, counts.get(status, 0), meaning) for status, meaning in STATUSES]
    lines += ['', '| Test | Status | Note |', '|---|---|---|']
    for row in table:
        test = row['test'].split(' ', 1)[1].replace('|', '\\|')
        note = row.get('note', '')
        if row.get('decision'):
            note += ' Decision: ' + row['decision']
        lines.append('| %s | `%s` | %s |' % (test, row.get('status', 'passes'), note.strip().replace('|', '\\|')))
    lines += ['', 'The client extension files batonc rejects, left out of `schema/extensions/`:', '']
    lines += ['- `%s`: %s' % (name, reason) for name, reason in sorted(excluded.items())]
    table_text = '\n'.join(lines) + '\n'
    start = text.index(begin) + len(begin)
    with open(path, 'w') as file:
        file.write(text[:start] + table_text + text[text.index(end):])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--relay', required=True)
    parser.add_argument('--harvest', required=True)
    parser.add_argument('--batonc', required=True)
    arguments = parser.parse_args()

    utils = os.path.join(arguments.relay, 'packages', 'relay-test-utils-internal')
    schema_directory = os.path.join(OUT, 'schema')
    extensions_directory = os.path.join(schema_directory, 'extensions')
    for directory in ('schema', 'sources', 'unsupported', 'scripts') + tuple(SUITES.values()):
        shutil.rmtree(os.path.join(OUT, directory), ignore_errors=True)
    os.makedirs(extensions_directory)
    shutil.copy(os.path.join(utils, 'testschema.graphql'), schema_directory)
    for name in sorted(os.listdir(os.path.join(utils, 'schema-extensions'))):
        shutil.copy(os.path.join(utils, 'schema-extensions', name), extensions_directory)
    config = os.path.join(OUT, 'baton.json')
    write_json(config, {
        'schema': 'schema/testschema.graphql',
        'schemaExtensions': ['schema/extensions'],
        'identity': {'types': {'Node': ['id']}},
    })
    excluded = exclude_rejected_extensions(arguments.batonc, config, extensions_directory)
    extension_paths = [os.path.join(extensions_directory, name) for name in sorted(os.listdir(extensions_directory))]
    kinds, fields = schema_types([os.path.join(schema_directory, 'testschema.graphql')] + extension_paths)

    expectations = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expectations.json')))
    cases, scripts, table, sources, unsupported = [], [], [], {}, {}
    all_definitions = {}
    for suite, directory in SUITES.items():
        test_path = os.path.join(arguments.relay, 'packages', 'relay-runtime', 'store', '__tests__', suite + '.js')
        definitions = documents_in(open(test_path).read())
        all_definitions.update(definitions)
        calls_by_test = {}
        for line in open(os.path.join(arguments.harvest, suite + '.jsonl')):
            call = json.loads(line)
            if call['function'] == 'normalize':
                calls_by_test.setdefault(call['test'], []).append(call)
        for test, calls in calls_by_test.items():
            name = '%s/%s' % (directory, slug(test))
            operation = calls[0]['operation']
            origin = '%s: %s' % (suite + '.js', test)
            row = {'test': test, 'origin': origin, 'name': 'relay/' + name, 'operation': operation, 'calls': len(calls)}
            table.append(row)
            if any(call['operation'] != operation for call in calls):
                row.update(status='not-ingested', note='payloads of several operations')
                continue
            status, note = reason_outside_concepts(calls)
            if status == 'not-ingested':
                row.update(status=status, note=note)
                continue
            if operation not in definitions:
                row.update(status='not-ingested', note='no authored document for `%s` in the test file' % operation)
                continue
            names = with_fragments(operation, definitions)
            text = '\n'.join(definitions[name] for name in names)
            rejection = batonc_rejection(arguments.batonc, config, text)
            try:
                dumps = [translate_dump(call['after'], kinds, fields) for call in calls]
            except Untranslatable as error:
                row.update(status='not-ingested', note='translation: %s' % error)
                continue
            if rejection:
                status, note = status or 'unsupported-feature', note or rejection
                unsupported[operation] = names
                document = 'relay/unsupported/%s.graphql' % operation
            else:
                sources[operation] = names
                document = 'relay/documents/%s.graphql' % operation
            expected = expectations.get(origin, {})
            status, note = expected.get('status', status), expected.get('note', note)
            marks = {key: value for key, value in (('status', status), ('note', note), ('decision', expected.get('decision'))) if value}
            row.update(marks)
            if len(calls) == 1:
                write_json(os.path.join(OUT, name + '.json'), response_of(calls[0]))
                with open(os.path.join(OUT, name + '.store.json'), 'w') as file:
                    file.write(dump_text(dumps[0]))
                case = {'name': 'relay/' + name, 'origin': origin}
                case.update(marks)
                case.update({
                    'operation': operation,
                    'kind': 'query',
                    'document': document,
                    'variables': calls[0]['variables'],
                    'responses': ['relay/%s.json' % name],
                    'records': 'relay/%s.store.json' % name,
                })
                if not case['variables']:
                    del case['variables']
                cases.append(case)
                continue
            steps = []
            for index, (call, dump) in enumerate(zip(calls, dumps)):
                stem = '%s-%d' % (name, index + 1)
                write_json(os.path.join(OUT, stem + '.json'), response_of(call))
                with open(os.path.join(OUT, stem + '.store.json'), 'w') as file:
                    file.write(dump_text(dump))
                step = {'operation': operation, 'response': 'relay/%s.json' % stem}
                if call['variables']:
                    step['variables'] = call['variables']
                steps.append({'payload': step, 'records': 'relay/%s.store.json' % stem})
            script_path = 'relay/scripts/%s.json' % slug(test)
            script = {'name': slug(test), 'origin': origin}
            script.update(marks)
            script['steps'] = steps
            write_json(os.path.join(SPEC, script_path), script)
            scripts.append(script_path)
            row['script'] = True

    os.makedirs(os.path.join(OUT, 'unsupported'), exist_ok=True)
    for operation, names in unsupported.items():
        with open(os.path.join(OUT, 'unsupported', operation + '.graphql'), 'w') as file:
            file.write('\n'.join(all_definitions[name] for name in names))
    os.makedirs(os.path.join(OUT, 'sources'), exist_ok=True)
    for operation, names in sources.items():
        with open(os.path.join(OUT, 'sources', operation + '.graphql'), 'w') as file:
            file.write('\n'.join(all_definitions[name] for name in names))
    defined = []
    for names in sources.values():
        defined += [name for name in names if name not in defined]
    os.makedirs(SWIFT, exist_ok=True)
    with open(os.path.join(SWIFT, 'RelayDocuments.swift'), 'w') as file:
        file.write(swift_documents(all_definitions, defined))

    write_json(os.path.join(OUT, 'manifest.json'), {
        'format': 3,
        'sources': {'config': 'relay/baton.json', 'directory': 'relay/sources'},
        'cases': cases,
        'scripts': scripts,
    })
    unused = sorted(set(expectations) - {row['origin'] for row in table if row.get('status') != 'not-ingested'})
    if unused:
        print('expectations.json names tests that were not ingested: %s' % '; '.join(unused), file=sys.stderr)
    write_json(os.path.join(OUT, 'harvest.json'), {'excludedExtensions': excluded, 'tests': table})
    write_table(table, excluded)
    counts = {}
    for row in table:
        counts[row.get('status', 'passes')] = counts.get(row.get('status', 'passes'), 0) + 1
    print('%d tests: %s' % (len(table), ', '.join('%d %s' % (count, status) for status, count in sorted(counts.items()))), file=sys.stderr)


if __name__ == '__main__':
    main()
