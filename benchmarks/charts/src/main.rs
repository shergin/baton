//! The figures in `BENCHMARKS.md`. Each one is the malevich plot the `kaz`
//! command in its comment draws; `Plot::to_svg` is that same grid as the card
//! a Markdown host can show. Numbers are the recorded bests in that file.
//!
//! ```sh
//! cargo run --manifest-path benchmarks/charts/Cargo.toml
//! ```

use std::path::PathBuf;

use malevich::{Frame, Line, Plot, PointStyle, Points, Scale, Theme};

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    read_path(&root);
    footprint(&root);
    apollo(&root);
}

/// `printf 'version ingest commit\n0.1 2.14 1.24\n…' | kaz line -H --fmt xyy -t 'Ingest and commit' --xlabel release -w 64 -h 16`
fn read_path(root: &std::path::Path) {
    let version = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6];
    // 0.1.0 table; 0.2.0 remeasurement; 0.3.0 through 0.6.0 prose bests.
    let ingest = [2.14, 2.08, 2.16, 2.53, 2.76, 2.76];
    let commit = [1.24, 1.15, 1.44, 1.34, 1.35, 1.37];
    let plot = Plot::new()
        .layer(Line::xy(&version, &ingest).label("ingest"))
        .layer(Line::xy(&version, &commit).label("commit"))
        .title("Ingest and commit")
        .x_label("release")
        .y_unit(malevich::scale::Unit::suffix(" ms"));
    write(root, "read-path", &plot, 64, 16);
}

/// `printf '1 0\n5 2.5\n10 5.8\n11 6.4\n20 6.5\n30 6.5\n42 6.5\n' | kaz line --fmt xy -t 'Footprint since page 1' --xlabel page -w 64 -h 16`
fn footprint(root: &std::path::Path) {
    // 0.2.0 lifetime table. Pages share no records; the buffer holds ten roots.
    let page = [1.0, 5.0, 10.0, 11.0, 20.0, 30.0, 42.0];
    let megabytes = [0.0, 2.5, 5.8, 6.4, 6.5, 6.5, 6.5];
    let plot = Plot::new()
        .layer(Line::xy(&page, &megabytes))
        .title("Footprint since page 1")
        .x_label("page")
        .y_unit(malevich::scale::Unit::suffix(" MB"));
    write(root, "footprint", &plot, 64, 16);
}

/// Log axis, so this is points rather than bars: a bar starts at zero, and
/// zero has no place on a log axis. `kaz scatter` has no band axis; the
/// layers are the grammar kaz emits for a labeled points plot.
fn apollo(root: &std::path::Path) {
    // 0.1.0 comparison table, in seconds. "store to data" is Baton's
    // availability check (115 µs) against Apollo's `store.load` (228 ms).
    let steps = [
        "to records",
        "commit",
        "to store",
        "same payload",
        "store to data",
        "one field",
        "JSON parse",
    ];
    let baton = [2.14e-3, 1.24e-3, 3.4e-3, 165e-6, 115e-6, 26e-9, 4.47e-3];
    let apollo = [317e-3, 1.39e-3, 318e-3, 3.99e-3, 228e-3, 296e-9, 5.73e-3];
    // Half a band apart, so two marks that share a column stay visible.
    let baton_band: Vec<f64> = (0..steps.len()).map(|index| index as f64 - 0.22).collect();
    let apollo_band: Vec<f64> = (0..steps.len()).map(|index| index as f64 + 0.22).collect();
    let plot = Plot::new()
        .y_scale(Scale::bands(steps))
        .layer(
            Points::xy(&baton, &baton_band)
                .style(PointStyle::Circle)
                .label("Baton"),
        )
        .layer(
            Points::xy(&apollo, &apollo_band)
                .style(PointStyle::Cross)
                .label("Apollo iOS 2.4"),
        )
        .log_x()
        .title("Baton and Apollo iOS 2.4")
        .x_label("seconds");
    write(root, "apollo", &plot, 72, 24);
}

fn write(root: &std::path::Path, name: &str, plot: &Plot<'_>, width: usize, height: usize) {
    for (suffix, theme) in [("", Theme::DARK), ("-light", Theme::LIGHT)] {
        let frame = Frame {
            theme,
            ..Frame::portable(width, height)
        };
        let path = root.join(format!("{name}{suffix}.svg"));
        std::fs::write(&path, plot.to_svg(&frame)).expect("write svg");
        println!("{}", path.display());
    }
}
