//! Tests of the writer: a line at its depth, a block's body one level
//! deeper than its head, and a blank line with nothing on it.

use super::*;

#[test]
fn a_block_writes_its_body_one_level_deeper_and_closes_at_its_own_level() {
    let mut writer = Writer::new();
    writer.block("public func hash(into hasher: inout Hasher)", |writer| {
        writer.line("hasher.combine(id)");
        writer.line("hasher.combine(first)");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "public func hash(into hasher: inout Hasher) {\n",
            "    hasher.combine(id)\n",
            "    hasher.combine(first)\n",
            "}\n",
        )
    );
}

#[test]
fn a_block_inside_a_block_writes_its_body_one_level_deeper_again() {
    let mut writer = Writer::new();
    writer.block("nonisolated public struct Lens: Baton.Lens", |writer| {
        writer.block(
            "@MainActor public var strict: TestStrict_character",
            |writer| {
                writer.block("get throws", |writer| {
                    writer.line("try .throwing(anchor)");
                });
            },
        );
        writer.line("public static let typeName = \"Character\"");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "nonisolated public struct Lens: Baton.Lens {\n",
            "    @MainActor public var strict: TestStrict_character {\n",
            "        get throws {\n",
            "            try .throwing(anchor)\n",
            "        }\n",
            "    }\n",
            "    public static let typeName = \"Character\"\n",
            "}\n",
        )
    );
}

#[test]
fn a_blank_line_is_empty_at_any_depth() {
    let mut writer = Writer::new();
    writer.block("nonisolated public struct Lens: Baton.Lens", |writer| {
        writer.line("public static let typeName = \"Character\"");
        writer.blank();
        writer.line("nonisolated public struct Origin: Baton.Lens {}");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "nonisolated public struct Lens: Baton.Lens {\n",
            "    public static let typeName = \"Character\"\n",
            "\n",
            "    nonisolated public struct Origin: Baton.Lens {}\n",
            "}\n",
        )
    );
}

#[test]
fn only_the_first_line_of_a_text_with_line_breaks_of_its_own_is_indented() {
    // A raw multi-line literal holds its lines as written, so indenting
    // them would change the string.
    let mut writer = Writer::new();
    writer.block(
        "nonisolated public struct TestQuery: Baton.Query",
        |writer| {
            writer.line(concat!(
                "public static let text = #\"\"\"\n",
                "query TestQuery { name }\n",
                "\"\"\"#",
            ));
        },
    );
    assert_eq!(
        writer.finish(),
        concat!(
            "nonisolated public struct TestQuery: Baton.Query {\n",
            "    public static let text = #\"\"\"\n",
            "query TestQuery { name }\n",
            "\"\"\"#\n",
            "}\n",
        )
    );
}

#[test]
fn the_depth_counts_the_blocks_the_next_line_is_written_in() {
    let mut writer = Writer::new();
    assert_eq!(writer.depth(), 0);
    writer.block("nonisolated public struct Lens: Baton.Lens", |writer| {
        assert_eq!(writer.depth(), 1);
        writer.block(
            "@MainActor public var strict: TestStrict_character",
            |writer| {
                assert_eq!(writer.depth(), 2);
            },
        );
        assert_eq!(writer.depth(), 1);
    });
    assert_eq!(writer.depth(), 0);
}

#[test]
fn a_documentation_comment_is_written_at_the_depth_of_what_it_documents() {
    let mut writer = Writer::new();
    writer.block("nonisolated public struct Lens: Baton.Lens", |writer| {
        writer.doc("Whether the server has edges after the last one.");
        writer.line("@MainActor public var hasNext: Bool { anchor.hasNext(Self.connection) }");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "nonisolated public struct Lens: Baton.Lens {\n",
            "    /// Whether the server has edges after the last one.\n",
            "    @MainActor public var hasNext: Bool { anchor.hasNext(Self.connection) }\n",
            "}\n",
        )
    );
}
