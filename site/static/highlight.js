// The site's highlighter, in JavaScript, for what the playground prints:
// Swift and Kotlin with the GraphQL inside a marker's string highlighted
// as GraphQL, GraphQL itself, and JSON. The same one-letter classes as
// the generator's highlighter, so the same stylesheet colours both.

const SWIFT_KEYWORDS = new Set("actor as assert associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while".split(" "));
const KOTLIN_KEYWORDS = new Set("abstract as break by catch class companion const constructor continue data do else enum false final finally for fun get if import in infix inline interface internal is it lateinit null object open operator override package private protected public return sealed set super suspend this throw true try typealias val var when where while".split(" "));
const GRAPHQL_KEYWORDS = new Set("query mutation subscription fragment on type interface union enum input scalar schema extend directive implements true false null".split(" "));
const MARKERS = new Set(["Fragment", "Query", "Mutation", "Subscription"]);

export const escape = (text) =>
  text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

const span = (cls, text) => `<span class="${cls}">${escape(text)}</span>`;
const isIdentStart = (c) => /[\p{L}_]/u.test(c);
const isIdent = (c) => /[\p{L}\p{N}_]/u.test(c);

function stringEnd(chars, start, quote) {
  let i = start + 1;
  while (i < chars.length) {
    if (chars[i] === "\\") {
      i += 2;
      continue;
    }
    if (chars[i] === quote) return i + 1;
    i += 1;
  }
  return chars.length;
}

function tripleEnd(chars, start) {
  let i = start + 3;
  while (i + 2 < chars.length) {
    if (chars[i] === '"' && chars[i + 1] === '"' && chars[i + 2] === '"') return i + 3;
    i += 1;
  }
  return chars.length;
}

function numberEnd(chars, start) {
  let i = start;
  while (i < chars.length && (/[0-9A-Za-z_]/.test(chars[i]) || (chars[i] === "." && /[0-9]/.test(chars[i + 1] ?? "")))) i += 1;
  return i;
}

function host(code, keywords, kotlin) {
  const chars = [...code];
  let out = "";
  let i = 0;
  let documentNext = false;
  while (i < chars.length) {
    const c = chars[i];
    if (c === "/" && chars[i + 1] === "/") {
      let end = chars.indexOf("\n", i);
      if (end < 0) end = chars.length;
      out += span("c", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (c === "/" && chars[i + 1] === "*") {
      let end = i + 2;
      while (end < chars.length && !(chars[end] === "*" && chars[end + 1] === "/")) end += 1;
      end = Math.min(end + 2, chars.length);
      out += span("c", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (c === "$" && kotlin) {
      let end = i;
      while (end < chars.length && chars[end] === "$") end += 1;
      if (chars[end] === '"') {
        out += span("s", chars.slice(i, end).join(""));
        i = end;
        continue;
      }
    }
    if (c === '"') {
      const triple = chars[i + 1] === '"' && chars[i + 2] === '"';
      const end = triple ? tripleEnd(chars, i) : stringEnd(chars, i, '"');
      const quote = triple ? 3 : 1;
      const close = Math.max(end - quote, i + quote);
      if (documentNext) {
        out += span("s", chars.slice(i, i + quote).join(""));
        out += `<span class="gql">${graphql(chars.slice(i + quote, close).join(""))}</span>`;
        out += span("s", chars.slice(close, end).join(""));
        documentNext = false;
      } else {
        out += span("s", chars.slice(i, end).join(""));
      }
      i = end;
      continue;
    }
    if (c === "@") {
      let end = i + 1;
      while (end < chars.length && (isIdent(chars[end]) || chars[end] === ".")) end += 1;
      const word = chars.slice(i + 1, end).join("");
      const bare = word.split(".").pop();
      if (MARKERS.has(bare)) {
        out += span("m", chars.slice(i, end).join(""));
        documentNext = true;
      } else {
        out += span("a", chars.slice(i, end).join(""));
      }
      i = end;
      continue;
    }
    if (/[0-9]/.test(c)) {
      const end = numberEnd(chars, i);
      out += span("n", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (isIdentStart(c)) {
      let end = i + 1;
      while (end < chars.length && isIdent(chars[end])) end += 1;
      const word = chars.slice(i, end).join("");
      if (keywords.has(word)) out += span("k", word);
      else if (/^\p{Lu}/u.test(word)) out += span("t", word);
      else if (chars[end] === "(") out += span("f", word);
      else out += escape(word);
      i = end;
      continue;
    }
    out += escape(c);
    i += 1;
  }
  return out;
}

export function graphql(code) {
  const chars = [...code];
  let out = "";
  let i = 0;
  while (i < chars.length) {
    const c = chars[i];
    if (c === "#") {
      let end = chars.indexOf("\n", i);
      if (end < 0) end = chars.length;
      out += span("c", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (c === '"') {
      const triple = chars[i + 1] === '"' && chars[i + 2] === '"';
      const end = triple ? tripleEnd(chars, i) : stringEnd(chars, i, '"');
      out += span("s", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (c === "$" || c === "@") {
      let end = i + 1;
      while (end < chars.length && isIdent(chars[end])) end += 1;
      out += span(c === "$" ? "v" : "d", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (c === "." && chars[i + 1] === "." && chars[i + 2] === ".") {
      let end = i + 3;
      while (end < chars.length && isIdent(chars[end])) end += 1;
      out += span("p", "...") + span("r", chars.slice(i + 3, end).join(""));
      i = end;
      continue;
    }
    if (/[0-9]/.test(c) || (c === "-" && /[0-9]/.test(chars[i + 1] ?? ""))) {
      const end = Math.max(numberEnd(chars, i + 1), i + 1);
      out += span("n", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (isIdentStart(c)) {
      let end = i + 1;
      while (end < chars.length && isIdent(chars[end])) end += 1;
      const word = chars.slice(i, end).join("");
      let n = end;
      while (n < chars.length && chars[n] === " ") n += 1;
      const followsColon = chars[n] === ":";
      if (GRAPHQL_KEYWORDS.has(word) && !followsColon) out += span("k", word);
      else if (/^\p{Lu}/u.test(word)) out += span("t", word);
      else if (followsColon) out += span("a", word);
      else out += span("f", word);
      i = end;
      continue;
    }
    out += escape(c);
    i += 1;
  }
  return out;
}

export function json(code) {
  const chars = [...code];
  let out = "";
  let i = 0;
  while (i < chars.length) {
    const c = chars[i];
    if (c === '"') {
      const end = stringEnd(chars, i, '"');
      let rest = end;
      while (rest < chars.length && /\s/.test(chars[rest])) rest += 1;
      out += span(chars[rest] === ":" ? "a" : "s", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (/[0-9-]/.test(c)) {
      const end = Math.max(numberEnd(chars, i + 1), i + 1);
      out += span("n", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    if (/[A-Za-z]/.test(c)) {
      let end = i;
      while (end < chars.length && /[A-Za-z]/.test(chars[end])) end += 1;
      out += span("k", chars.slice(i, end).join(""));
      i = end;
      continue;
    }
    out += escape(c);
    i += 1;
  }
  return out;
}

export function highlight(language, code) {
  switch (language) {
    case "swift":
      return host(code, SWIFT_KEYWORDS, false);
    case "kotlin":
      return host(code, KOTLIN_KEYWORDS, true);
    case "graphql":
      return graphql(code);
    case "json":
      return json(code);
    default:
      return escape(code);
  }
}
