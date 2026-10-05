//! A mutation's optimistic-response builders.
//!
//! A builder names the runtime's module only in types, where Swift looks up
//! types alone: a payload field named `Baton` is a property that hides the
//! module from the expressions of its builder and of every builder nested
//! in it. A value takes its type from the dictionary it is stored in, as
//! `.init(name)` does.

use super::swift::{SwiftType, member, parameter, scalar_type, swift_literal};
use super::writer::Writer;
use crate::decide::{BuilderPlan, BuilderValue};

/// Writes an optimistic-response builder and those nested in it.
pub(super) fn builder(writer: &mut Writer, builder: &BuilderPlan) {
    let variable = SwiftType::runtime("Variable");
    writer.doc(
        "A partial response to show before the server answers; absent fields leave the store untouched.",
    );
    writer.block(
        format!(
            "nonisolated public struct {}: Sendable",
            SwiftType::named(&builder.name)
        ),
        |writer| {
            let collected = &builder.collected;
            let mut parameters: Vec<String> = Vec::new();
            let mut assignments: Vec<String> = Vec::new();
            let mut renders: Vec<String> = Vec::new();
            for field in &builder.fields {
                let property = member(&field.key);
                let key = swift_literal(&field.key);
                let local = &field.local;
                let swift_type = match &field.value {
                    BuilderValue::Scalar { shape } => scalar_type(*shape),
                    BuilderValue::Object {
                        builder,
                        plural: true,
                    } => SwiftType::named(builder).array(),
                    BuilderValue::Object {
                        builder,
                        plural: false,
                    } => SwiftType::named(builder),
                }
                .optional();
                writer.line(format!("public var {property}: {swift_type}"));
                parameters.push(format!(
                    "{}: {swift_type} = nil",
                    parameter(&field.key, local)
                ));
                assignments.push(format!("self.{property} = {local}"));
                // A field of a plain name binds its value by its own name;
                // `self` binds it by another, which needs the property
                // spelled.
                let bind = if *local == property {
                    local.clone()
                } else {
                    format!("{local} = self.{property}")
                };
                renders.push(match &field.value {
                    BuilderValue::Scalar { .. } => {
                        format!("if let {bind} {{ {collected}[{key}] = .init({local}) }}")
                    }
                    BuilderValue::Object { plural: true, .. } => {
                        format!(
                            "if let {bind} {{ {collected}[{key}] = .list({local}.map(\\.variable)) }}"
                        )
                    }
                    BuilderValue::Object { plural: false, .. } => {
                        format!("if let {bind} {{ {collected}[{key}] = {local}.variable }}")
                    }
                });
            }
            writer.block(
                format!("public init({})", parameters.join(", ")),
                |writer| {
                    for assignment in &assignments {
                        writer.line(assignment);
                    }
                },
            );
            writer.block(format!("public var variable: {variable}"), |writer| {
                writer.line(format!("var {collected}: [String: {variable}] = [:]"));
                for render in &renders {
                    writer.line(render);
                }
                writer.line(format!("return .object({collected})"));
            });
            for child in &builder.nested {
                writer.blank();
                self::builder(writer, child);
            }
        },
    );
}
