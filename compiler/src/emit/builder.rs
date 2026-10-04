//! A mutation's optimistic-response builders.
//!
//! A builder names the runtime's module only in types, where Swift looks up
//! types alone: a payload field named `Baton` is a property that hides the
//! module from the expressions of its builder and of every builder nested
//! in it. A value takes its type from the dictionary it is stored in, as
//! `.init(name)` does.

use std::fmt::Write as _;

use super::swift::parameter;
use crate::decide::{BuilderPlan, BuilderValue};
use crate::names::escape;

/// Writes an optimistic-response builder and those nested in it.
pub(super) fn builder(output: &mut String, builder: &BuilderPlan, indent: &str) {
    let _ = writeln!(
        output,
        "{indent}/// A partial response to show before the server answers; absent fields leave the store untouched."
    );
    let _ = writeln!(
        output,
        "{indent}nonisolated public struct {}: Sendable {{",
        builder.name
    );
    let inner = format!("{indent}    ");
    let mut parameters: Vec<String> = Vec::new();
    let mut assignments: Vec<String> = Vec::new();
    let mut renders: Vec<String> = Vec::new();
    for field in &builder.fields {
        let property = escape(&field.key);
        let key = &field.key;
        let local = &field.local;
        let swift_type = match &field.value {
            BuilderValue::Scalar { swift_type } => swift_type.clone(),
            BuilderValue::Object {
                builder,
                plural: true,
            } => format!("[{builder}]"),
            BuilderValue::Object {
                builder,
                plural: false,
            } => builder.clone(),
        };
        let _ = writeln!(output, "{inner}public var {property}: {swift_type}?");
        parameters.push(format!(
            "{}: {swift_type}? = nil",
            parameter(&field.key, local)
        ));
        assignments.push(format!("self.{property} = {local}"));
        // A field of a plain name binds its value by its own name; `self`
        // binds it by another, which needs the property spelled.
        let bind = if *local == property {
            local.clone()
        } else {
            format!("{local} = self.{property}")
        };
        renders.push(match &field.value {
            BuilderValue::Scalar { .. } => {
                format!("if let {bind} {{ fields[\"{key}\"] = .init({local}) }}")
            }
            BuilderValue::Object { plural: true, .. } => {
                format!("if let {bind} {{ fields[\"{key}\"] = .list({local}.map(\\.variable)) }}")
            }
            BuilderValue::Object { plural: false, .. } => {
                format!("if let {bind} {{ fields[\"{key}\"] = {local}.variable }}")
            }
        });
    }
    let _ = writeln!(output, "{inner}public init({}) {{", parameters.join(", "));
    for assignment in &assignments {
        let _ = writeln!(output, "{inner}    {assignment}");
    }
    let _ = writeln!(output, "{inner}}}");
    let _ = writeln!(output, "{inner}public var variable: Baton.Variable {{");
    let _ = writeln!(
        output,
        "{inner}    var fields: [String: Baton.Variable] = [:]"
    );
    for render in &renders {
        let _ = writeln!(output, "{inner}    {render}");
    }
    let _ = writeln!(output, "{inner}    return .object(fields)");
    let _ = writeln!(output, "{inner}}}");
    for child in &builder.nested {
        output.push('\n');
        self::builder(output, child, &inner);
    }
    let _ = writeln!(output, "{indent}}}");
}
