"""Transcribes the plan literals of the Swift goldens into Kotlin for the
Kotlin runtime's spec harness, until the Kotlin emitter exists.

Run from the repository's root:

    python3 kotlin/scripts/transcribe-plans.py

It rewrites kotlin/baton/src/jvmTest/kotlin/baton/TestPlans.kt.
"""
import glob
import json
import os
import re

repo = os.getcwd()
output = repo + "/kotlin/baton/src/jvmTest/kotlin/baton/TestPlans.kt"
goldens = repo + "/compiler/src/tests/goldens/"


def kotlin_string(match):
    # Swift and Kotlin share their escapes but for `$`, which starts a template in Kotlin.
    return match.group(0).replace("$", "\\$")


STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def outside_strings(text, transform):
    """Applies transform to the text between string literals."""
    parts = []
    last = 0
    for match in STRING.finditer(text):
        parts.append(transform(text[last:match.start()]))
        parts.append(kotlin_string(match))
        last = match.end()
    parts.append(transform(text[last:]))
    return "".join(parts)


def contextual(text):
    # Values whose type depends on where they stand.
    text = re.sub(r"\b(after|before): \.variable\(", r"\1: ConnectionCursor.Variable(", text)
    text = re.sub(r"\b(after|before): \.literal\b", r"\1: ConnectionCursor.Literal", text)
    text = re.sub(r"\bconnections: \.variable\(", "connections: Edit.Connections.Variable(", text)
    text = re.sub(r"\bconnections: \.literal\(", "connections: Edit.Connections.Literal(", text)

    def lookup(match):
        body = match.group(0)
        body = body.replace(".variable(", "Lookup.Key.Variable(").replace(".literal(", "Lookup.Key.Literal(")
        return body

    text = re.sub(r"Baton\.Lookup\(.*?\]\)", lookup, text)

    def dynamic(match):
        return match.group(0).replace(".variable(", "KeyPart.Variable(").replace(".literal(", "KeyPart.Literal(")

    text = re.sub(r"Baton\.DynamicKey\(.*\)$", dynamic, text)
    return text


EDIT_KINDS = {
    "appendEdge": "APPEND_EDGE", "prependEdge": "PREPEND_EDGE", "appendNode": "APPEND_NODE",
    "prependNode": "PREPEND_NODE", "deleteEdge": "DELETE_EDGE", "deleteRecord": "DELETE_RECORD",
}


def code(text):
    """Swift's plan expression syntax to Kotlin's, outside string literals."""
    text = re.sub(r"\bkind: \.(string|int|double|bool|custom)\b", lambda m: "kind: ScalarKind." + m.group(1).upper(), text)
    text = re.sub(r"\bkind: \.(" + "|".join(EDIT_KINDS) + r")\b", lambda m: "kind: Edit.Kind." + EDIT_KINDS[m.group(1)], text)
    text = text.replace(".fixed(", "StorageKey.Fixed(").replace(".dynamic(", "StorageKey.Dynamic(")
    text = re.sub(r"(?<![\w.])\.scalar\(", "PlanField.scalar(", text)
    text = re.sub(r"(?<![\w.])\.linked\(", "PlanField.linked(", text)
    text = re.sub(r"(?<![\w.])\.init\(types:", "Selection.Variant(types:", text)
    text = re.sub(r"(?<![\w.])\.init\(", "Selection.MembershipAnswer(", text)
    text = text.replace("Baton.", "")
    text = text.replace("abstract:", "isAbstract:")
    text = re.sub(r"\bnil\b", "null", text)
    text = text.replace("[", "listOf(").replace("]", ")")
    text = re.sub(r"\b([A-Za-z_]\w*): ", r"\1 = ", text)
    return text


def translate(expression):
    expression = contextual(expression)
    return outside_strings(expression, code)


shared = open(goldens + "Baton.baton.swift").read()


def block(text, name):
    start = text.index("nonisolated enum %s {" % name)
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise ValueError(name)


lines = []
emit = lines.append
emit("// Transcribed from the plan literals of compiler/src/tests/goldens/*.baton.swift")
emit("// until the Kotlin emitter prints them, by kotlin/scripts/transcribe-plans.py;")
emit("// run it again rather than edit.")
emit("@file:Suppress(\"ObjectPropertyName\", \"PropertyName\", \"unused\")")
emit("")
emit("package baton")
emit("")

# Types.
emit("internal object Types {")
for line in block(shared, "Types").splitlines():
    line = line.strip()
    match = re.match(r'static let (\w+) = Baton\.Registry\.type\("([^"]+)"(, transient: true)?\)$', line)
    if match:
        transient = ", transient = true" if match.group(3) else ""
        emit('    val %s = Registry.type("%s"%s)' % (match.group(1), match.group(2), transient))
        continue
    match = re.match(r"static let transient = Baton\.Transient\(types: \[(.*?)\], fields: \[(.*)\]\)$", line)
    if match:
        fields = re.sub(r'\((\w+), ("[^"]*")\)', r"\1 to \2", match.group(2))
        emit("    val transient = Transient(types = listOf(%s), fields = listOf(%s))" % (match.group(1), fields))
        continue
    match = re.match(r"static let (\w+) = Baton\.Members\((\w+), \[(.*)\]\)$", line)
    if match:
        emit("    val %s = Members(%s, listOf(%s))" % (match.group(1), match.group(2), match.group(3)))
emit("}")
emit("")

# Slots.
emit("internal object Slots {")
for line in block(shared, "Slots").splitlines()[1:-1]:
    stripped = line.strip()
    match = re.match(r"nonisolated enum (\w+) \{$", stripped)
    if match:
        emit("    object %s {" % match.group(1))
        continue
    if stripped == "}":
        emit("    }")
        continue
    match = re.match(r"static let (\w+) = (.*)$", stripped)
    if match:
        emit("        val %s = %s" % (match.group(1), translate(match.group(2))))
emit("}")
emit("")

# Guards.
emit("internal object Guards {")
for line in block(shared, "Guards").splitlines():
    match = re.match(r'\s*static let (\w+) = Baton\.Guard\(("[^"]*"), passing: (true|false)\)$', line)
    if match:
        emit("    @JvmField val %s = Guard(%s, passing = %s)" % (match.group(1), kotlin_string(re.match(".*", match.group(2))), match.group(3)))
emit("}")
emit("")

# The operations the manifest names.
manifest = json.load(open(repo + "/spec/manifest.json"))
operations = sorted(set(case["operation"] for case in manifest["cases"]))
sources = {}
for path in sorted(glob.glob(goldens + "*.baton.swift")):
    text = open(path).read()
    for match in re.finditer(r"public struct (\w+): Baton\.(Query|Mutation|Subscription) \{", text):
        sources.setdefault(match.group(1), (text, match.start()))

emit("/** The plans of the operations the manifest names, by operation name. */")
emit("internal object TestPlans {")
emit("    val byOperation: Map<String, () -> Plan> = mapOf(")
for operation in operations:
    emit('        "%s" to { %sPlan.plan },' % (operation, operation))
emit("    )")
emit("}")
for operation in operations:
    text, start = sources[operation]
    plan_start = text.index("static let plan = ", start)
    end = text.index("nonisolated public struct Data", plan_start)
    body = text[plan_start:end]
    emit("")
    emit("private object %sPlan {" % operation)
    plan_line = body.splitlines()[0]
    match = re.match(r"static let plan = Baton\.Plan\(root: (\w+), transient: Types\.transient\)$", plan_line.strip())
    emit("    val plan: Plan by lazy { Plan(root = %s, transient = Types.transient) }" % match.group(1))
    for selection in re.finditer(r"private static let (selection\d+): Baton\.Selection = (Baton\.Selection\(.*?\n    \]\))\n", body, re.S):
        expression = translate(selection.group(2))
        expression = "\n".join(line[4:] if line.startswith("    ") else line for line in expression.splitlines())
        expression = expression.replace(",\n    )", "\n    )").replace(",\n)", "\n)")
        emit("    private val %s: Selection by lazy {" % selection.group(1))
        emit("        " + expression.replace("\n", "\n        "))
        emit("    }")
    emit("}")

open(output, "w").write("\n".join(lines) + "\n")
