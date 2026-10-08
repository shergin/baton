//! A mutation's optimistic-response builders in Kotlin: a class per
//! selection set, every field a constructor parameter that defaults to
//! null, which renders the `Variable` a response's data is and, on the
//! response's own, the payload the door takes.

use super::super::writer::Writer;
use super::literal::{Base, Converters, ValueShape, jvm_getters, string_literal};
use crate::decide::{BuilderPlan, BuilderValue};
use crate::kotlin_names::escape;

/// Writes an optimistic-response builder and those nested in it.
pub(super) fn builder(writer: &mut Writer, builder: &BuilderPlan, converters: &Converters) {
    writer.line(
        "/** A partial response to show before the server answers; absent fields leave the store untouched. */",
    );
    let names: Vec<&str> = builder
        .fields
        .iter()
        .map(|field| field.key.as_str())
        .collect();
    let getters = jvm_getters(&names, &["getVariable", "getPayload", "getClass"]);
    let mut parameters: Vec<String> = Vec::new();
    let mut entries: Vec<String> = Vec::new();
    for (field, getter) in builder.fields.iter().zip(getters) {
        let property = escape(&field.key);
        let kotlin_type = match &field.value {
            BuilderValue::Scalar { shape } => converters.scalar_type(shape),
            BuilderValue::Object {
                builder,
                plural: true,
            } => format!("List<{}>", escape(builder)),
            BuilderValue::Object {
                builder,
                plural: false,
            } => escape(builder),
        };
        let annotation = getter
            .map(|getter| format!("@get:JvmName({}) ", string_literal(&getter)))
            .unwrap_or_default();
        parameters.push(format!("{annotation}val {property}: {kotlin_type}? = null"));
        // A field is read through `this`, so no name it takes is read as
        // the getter's backing field.
        let read = format!("this.{property}");
        let value = match &field.value {
            BuilderValue::Scalar { shape } => {
                let shape = ValueShape {
                    base: Base::Scalar(&shape.primitive),
                    list: shape.list,
                    non_null: true,
                };
                format!(
                    "{read}?.let {{ {} }}",
                    converters.value_expression("it", &shape)
                )
            }
            BuilderValue::Object { plural: true, .. } => {
                format!("{read}?.let {{ Variable.List(it.map {{ element -> element.variable }}) }}")
            }
            BuilderValue::Object { plural: false, .. } => format!("{read}?.variable"),
        };
        entries.push(format!("{} to {value}", string_literal(&field.key)));
    }
    let head = format!("class {}({})", escape(&builder.name), parameters.join(", "));
    writer.block(head, |writer| {
        writer.line("/** The response's data as a variable, an absent field left out. */");
        writer.line("@Generated");
        writer.line("val variable: Variable");
        let object = if entries.is_empty() {
            "Variable.Object(emptyMap())".to_string()
        } else {
            format!(
                "Variable.Object(Variables.of({}).values)",
                entries.join(", ")
            )
        };
        writer.line(format!("    get() = {object}"));
        if builder.payload {
            writer.line("/** The response this builder describes, as the bytes the door takes. */");
            writer.line("val payload: Payload get() = Payload(data = variable)");
        }
        for child in &builder.nested {
            writer.blank();
            self::builder(writer, child, converters);
        }
    });
}
