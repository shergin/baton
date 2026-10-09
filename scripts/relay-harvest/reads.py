"""What a Relay reader test reads, as Baton spec rows and the Swift that
reads each row through the generated lens.

Relay's `read` gives the data a selector reads, masked: a fragment spread is
a reference, a type condition's fields sit in the object they refine, a
`@catch` field is `{ok, value}` or `{ok, errors}`, and a list keeps its null
elements. Its field errors say what would throw when a component renders:
a `@required(action: THROW)` field that is null, an error under
`@throwOnFieldError`. Baton reads the same facts through a lens's
accessors: a type condition is an accessor of its own (`asUser`), a list of
records drops its null elements, a throwing read throws at the field, and an
operation that cannot be shown fails its handle. The rows say Relay's
answer in Baton's terms; the accessors come from the compiler's report,
which lists every accessor's name, the response key it reads and its shape.
"""

import json
import re

# Swift's keywords, which a member access spells in backticks.
KEYWORDS = {
    'associatedtype', 'class', 'deinit', 'enum', 'extension', 'fileprivate', 'func', 'import',
    'init', 'inout', 'internal', 'let', 'open', 'operator', 'private', 'protocol', 'public',
    'rethrows', 'static', 'struct', 'subscript', 'typealias', 'var', 'break', 'case', 'continue',
    'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard', 'if', 'in', 'repeat', 'return',
    'switch', 'where', 'while', 'as', 'catch', 'false', 'is', 'nil', 'super', 'self', 'Self',
    'throw', 'throws', 'true', 'try', 'Type',
}


class Unreadable(Exception):
    """A read the rows cannot say: the reason the test is not ingested."""


class Chain:
    """A Swift expression that reads down from the operation's data,
    whether its last member's type is optional, which the next member is
    reached through with `?.`, and whether it throws."""

    def __init__(self, expression, optional=False, throws=False):
        self.expression, self.optional, self.throws = expression, optional, throws

    def member(self, accessor):
        name = accessor['name']
        name = '`%s`' % name if name in KEYWORDS else name
        return Chain(
            '%s%s.%s' % (self.expression, '?' if self.optional else '', name),
            accessor.get('optional', False) or accessor['read'] == 'condition',
            self.throws or accessor.get('throws', False),
        )

    def element(self, index):
        return Chain('%s%s.element(%d)' % (self.expression, '?' if self.optional else '', index), True, self.throws)

    def success(self):
        """A `@catch` result's value, nil on a failure."""
        return Chain('(try? %s%s.get())' % (self.expression, '?' if self.optional else ''), True, False)

    def read(self, helper):
        return '%s(%s%s)' % (helper, 'try ' if self.throws else '', self.expression)


def accessor_for(lens, key, type_name, chain):
    """The accessor of `lens` that reads `key` on an object of `type_name`,
    through the type condition that refines it when the field is the
    condition's, and the chain that reaches it."""
    for accessor in lens['accessors']:
        if accessor.get('key') == key and accessor['read'] in ('scalar', 'linked', 'aliased'):
            return accessor, chain
    for accessor in lens['accessors']:
        if accessor['read'] != 'condition' or type_name not in accessor.get('types', []):
            continue
        found = accessor_for(accessor['lens'], key, type_name, chain.member(accessor))
        if found:
            return found
    return None


def is_reference(value):
    """A masked fragment spread: an object of Relay's own keys only."""
    return isinstance(value, dict) and value and all(key.startswith('__') for key in value)


def required_path(error):
    """The path a `@required` error names in its message, or None."""
    match = re.search(r"Missing @required value at path '([^']*)'", error.get('message', ''))
    return match.group(1) if match else None


class Reads:
    """The rows of one read and the Swift expression of each."""

    def __init__(self, operation_lens, response_errors):
        self.lens = operation_lens
        self.response_errors = response_errors
        self.rows = []
        self.swift = []

    def add(self, path, row, expression):
        row = dict({'path': '.'.join(path)}, **row)
        self.rows.append(row)
        if expression is not None:
            self.swift.append((row['path'], expression))

    def walk(self, value, response, lens, chain, path, response_path):
        type_name = (response or {}).get('__typename', lens['type'])
        for key, item in value.items():
            if key.startswith('__') or is_reference(item):
                continue
            found = accessor_for(lens, key, type_name, chain)
            if not found:
                raise Unreadable('no accessor of `%s` reads `%s`' % (lens['type'], '.'.join(path + [key])))
            accessor, reaching = found
            here = reaching.member(accessor)
            at = path + [key]
            below = response.get(key) if isinstance(response, dict) else None
            if accessor.get('caught'):
                self.caught(item, below, accessor, here, at, response_path + [key])
            elif accessor['read'] == 'scalar':
                self.add(at, {'value': item}, here.read('relayValue'))
            else:
                self.link(item, below, accessor, here, at, response_path + [key])

    def error_paths(self, errors, response_path):
        """The dotted paths of a `@catch` result's errors: a `@required`
        error's from its message, an error of Relay's own from its path,
        and a field error's from the response's errors under the caught
        field, which Relay's result does not repeat."""
        below = ['.'.join(str(part) for part in error['path']) for error in self.response_errors
                 if error.get('path', [])[:len(response_path)] == response_path]
        paths = []
        for error in errors:
            required = required_path(error)
            if required:
                paths.append(required)
            elif error.get('path'):
                paths.append('.'.join(str(part) for part in error['path']))
            elif below:
                paths.append(below.pop(0))
            else:
                raise Unreadable('a caught error the response does not hold')
        return sorted(paths)

    def caught(self, item, response, accessor, chain, path, response_path):
        if not isinstance(item, dict) or 'ok' not in item:
            raise Unreadable('`%s` is caught and Relay read no result' % '.'.join(path))
        if not item['ok']:
            result = {'ok': False, 'errors': self.error_paths(item.get('errors', []), response_path)}
            self.add(path, {'result': result}, chain.read('relayResult'))
            return
        if accessor['read'] == 'scalar':
            self.add(path, {'result': {'ok': True, 'value': item.get('value')}}, chain.read('relayResult'))
            return
        self.add(path, {'result': {'ok': True}}, chain.read('relayResult'))
        if item.get('value') is not None:
            self.link(item['value'], response, accessor, chain.success(), path, response_path, row=False)

    def link(self, item, response, accessor, chain, path, response_path, row=True):
        if item is None:
            if row:
                self.add(path, {'value': None}, chain.read('relayLink'))
            return
        if accessor.get('list'):
            if not isinstance(item, list):
                raise Unreadable('`%s` is a list and Relay read no list' % '.'.join(path))
            index = 0
            for position, element in enumerate(item):
                if element is None:
                    continue
                below = response[position] if isinstance(response, list) and position < len(response) else None
                self.walk(element, below, accessor['lens'], chain.element(index), path + [str(index)],
                          response_path + [position])
                index += 1
            return
        if not isinstance(item, dict):
            raise Unreadable('`%s` is a link and Relay read a scalar' % '.'.join(path))
        self.walk(item, response, accessor['lens'], chain, path, response_path)

    def thrown(self, field_path, response):
        """A field Relay's component would throw at: the read throws in
        Baton, and the nulls Relay wrote on the way to it are not rows."""
        lens, chain, here = self.lens, Chain('data'), response
        keys = field_path.split('.')
        for position, key in enumerate(keys):
            found = accessor_for(lens, key, (here or {}).get('__typename', lens['type']), chain)
            if not found:
                raise Unreadable('no accessor reads `%s`, which throws' % field_path)
            accessor, reaching = found
            chain = reaching.member(accessor)
            if position < len(keys) - 1:
                if accessor.get('list') or accessor.get('caught'):
                    raise Unreadable('`%s` throws below a list or a result' % field_path)
                lens, here = accessor['lens'], (here or {}).get(key)
        helper = 'relayValue' if accessor['read'] == 'scalar' else 'relayLink'
        self.rows = [row for row in self.rows if not field_path.startswith(row['path'] + '.')]
        self.swift = [(path, expression) for path, expression in self.swift if not field_path.startswith(path + '.')]
        self.add(keys, {'throws': 'requiredField'}, chain.read(helper))


def reads_of(answer, response, lens):
    """The rows a Relay reader test's answer says, and the Swift of each."""
    reads = Reads(lens, response.get('errors') or [])
    errors = answer.get('fieldErrors') or []
    thrown = [error['fieldPath'] for error in errors
              if error.get('kind') == 'missing_required_field.throw' and not error.get('handled')]
    # Relay reports a field again for each `@required` its null cascades
    # through, and throws the first: the deepest, the field that is null.
    thrown = [path for path in thrown if not any(other.startswith(path + '.') for other in thrown)]
    if answer['data'] is None:
        # A field that throws in Baton is where Relay's render would have
        # thrown; only a bubbling `@required` fails the operation itself.
        if thrown:
            for field_path in thrown:
                reads.thrown(field_path, response.get('data'))
            return reads
        if not any((error.get('kind') or '').startswith('missing_required_field') for error in errors):
            raise Unreadable('Relay read no data and no `@required` field bubbled')
        reads.add([], {'throws': 'requiredField'}, None)
        return reads
    reads.walk(answer['data'], response.get('data'), lens, Chain('data'), [], [])
    for field_path in thrown:
        reads.thrown(field_path, response.get('data'))
    unhandled = [error for error in errors if error.get('handled') is False]
    if any(error.get('kind') == 'relay_field_payload.error' and error.get('shouldThrow') for error in unhandled):
        reads.add([], {'throws': 'fieldErrors'}, None)
    elif any(error.get('kind') == 'missing_expected_data.throw' for error in unhandled):
        reads.add([], {'throws': 'missingData'}, None)
    return reads


def swift_reads(entries):
    """The Swift test target's reads: one function per script, a case per
    row, each reading through the generated lens of the script's operation."""
    lines = [
        '// Generated by scripts/relay-harvest/translate.py from the reads of',
        "// Relay's reader tests (MIT, Meta Platforms, Inc. and affiliates). Do not",
        '// edit; run the translator again.',
        '',
        '@_spi(Generated) import Baton',
        'import BatonSpec',
        '',
        'extension RelayReads {',
        '    /// The read at each row of each script, by the script\'s path.',
        '    static let readers: [String: @MainActor @Sendable (Anchor, String) throws -> Manifest.Value?] = [',
    ]
    for index, (path, _, _) in enumerate(entries):
        lines.append('        %s: read%d,' % (json.dumps(path), index))
    lines += ['    ]']
    for index, (path, operation, rows) in enumerate(entries):
        lines += [
            '',
            '    /// %s' % path,
            '    @MainActor static func read%d(_ anchor: Anchor, _ path: String) throws -> Manifest.Value? {' % index,
            '        let data = %s.Data(anchor: anchor)' % operation,
            '        switch path {',
        ]
        for row_path, expression in rows:
            lines.append('        case %s: return %s' % (json.dumps(row_path), expression))
        lines += ['        default: return nil', '        }', '    }']
    lines += ['}', '']
    return '\n'.join(lines)
