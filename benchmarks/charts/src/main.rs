//! The figures in `BENCHMARKS.md`. Each one is the malevich plot the `kaz`
//! command in its comment draws. The card around it is the same SVG chrome
//! `Plot::to_svg` writes; the plot rectangle is malevich's pixel raster
//! instead, so the series is anti-aliased. Numbers are the recorded bests
//! in that file.
//!
//! ```sh
//! cargo run --manifest-path benchmarks/charts/Cargo.toml
//! ```

use std::collections::BTreeMap;
use std::io::Read;
use std::path::PathBuf;

use flate2::read::ZlibDecoder;
use malevich::pixel::{Graphics, Protocol};
use malevich::{Frame, Line, Plot, PointStyle, Points, Scale, Theme};

/// Cell advance of malevich's SVG card (`malevich` `src/render/svg.rs`).
const CELL_W: f64 = 7.8;
const CELL_H: f64 = 16.0;
/// Text baseline below the row's top edge, matching that card.
const BASELINE: f64 = 12.5;
const PAD_X: f64 = 16.0;
const PAD_Y: f64 = 12.0;
/// Device pixels per cell. The card maps a cell to 7.8 by 16 CSS pixels,
/// so this is about two image pixels per CSS pixel.
const CELL_PX: (u16, u16) = (16, 32);

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    read_path(&root);
    footprint(&root);
    apollo(&root);
}

/// `printf 'version ingest commit\n0.1 2.14 1.24\n…' | kaz line -H --fmt xyy -t 'Ingest and commit' --xlabel release -w 64 -h 16`
fn read_path(root: &std::path::Path) {
    let version = [0.1, 0.2, 0.3, 0.4, 0.5];
    // 0.1.0 table; 0.2.0 remeasurement; 0.3.0, 0.4.0, and 0.5.0 prose bests.
    let ingest = [2.14, 2.08, 2.16, 2.53, 2.76];
    let commit = [1.24, 1.15, 1.44, 1.34, 1.35];
    let plot = Plot::new()
        .layer(Line::xy(&version, &ingest).label("ingest"))
        .layer(Line::xy(&version, &commit).label("commit"))
        .title("Ingest and commit")
        .x_label("release")
        .y_unit(malevich::scale::Unit::suffix(" ms"));
    write(root, "read-path", &plot, 64, 16, None);
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
        .y_unit(malevich::scale::Unit::suffix(" MB"))
        // The pixel stroke is centered on the value. 6.5 MB is the top of
        // the fitted axis, so the stroke would run through the title.
        .y_max(7.0);
    write(root, "footprint", &plot, 64, 16, None);
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
        .x_label("seconds")
        // A mark is centered on its value, and both extremes are the fitted
        // ends, so the stroke would be cut off. A decade of room on each
        // side leaves the rings and crosses intact.
        .x_min(1e-8)
        .x_max(1.0);
    // The default pixel stroke is a hairline. These marks have to stay
    // readable at card size, about a cell across.
    write(root, "apollo", &plot, 72, 24, Some(9));
}

fn write(
    root: &std::path::Path,
    name: &str,
    plot: &Plot<'_>,
    width: usize,
    height: usize,
    stroke: Option<u8>,
) {
    for (suffix, theme) in [("", Theme::DARK), ("-light", Theme::LIGHT)] {
        let frame = Frame {
            theme,
            ..Frame::portable(width, height)
        };
        let svg = compose(plot, &frame, stroke);
        let path = root.join(format!("{name}{suffix}.svg"));
        std::fs::write(&path, &svg).expect("write svg");
        println!("{} ({} bytes)", path.display(), svg.len());
    }
}

/// The cell-grid card, with the plot rectangle replaced by the pixel panel.
///
/// `Plot::to_svg` draws marks as quadrant blocks. Painting the pixel image
/// over those blocks would leave the staircase visible through the
/// transparent pixels, so marks that sit inside the panel are dropped
/// first. The panel is then malevich's iTerm2 PNG, composited onto the
/// card color and emitted as filled paths. An `<image>` would be smaller,
/// and GitHub's SVG sanitizer removes it.
fn compose(plot: &Plot<'_>, frame: &Frame, stroke: Option<u8>) -> String {
    let card = plot.to_svg(frame);
    let Some(panel) = plot.mapping(frame).plot_area() else {
        return card;
    };
    let panel_box = (
        PAD_X + panel.column as f64 * CELL_W,
        PAD_Y + panel.row as f64 * CELL_H,
        panel.width as f64 * CELL_W,
        panel.height as f64 * CELL_H,
    );
    let mut graphics = Graphics::new(Protocol::ITerm2).cell_size(CELL_PX.0, CELL_PX.1);
    if let Some(stroke) = stroke {
        graphics = graphics.stroke(stroke);
    }
    let rendered = plot.render_pixels(frame, &graphics);
    let png = extract_png(&rendered).expect("iTerm2 panel did not carry a PNG");
    let (background, foreground) = card_colors(frame.theme);
    let marks = panel_marks(&png, panel_box, background, foreground);

    let mut out = String::with_capacity(card.len() + marks.len());
    for line in card.lines() {
        if line.starts_with("<rect ") {
            if let Some(bounds) = rect_bounds(line)
                && contained(bounds, panel_box)
            {
                continue;
            }
        } else if line.starts_with("<text ")
            && let Some(bounds) = text_bounds(line)
            && contained(bounds, panel_box)
        {
            continue;
        }
        if line == "</svg>" {
            out.push_str(&marks);
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Card background and foreground, matching `Theme::card_colors`.
fn card_colors(theme: Theme) -> ([u8; 3], [u8; 3]) {
    if theme == Theme::LIGHT {
        ([0xff, 0xff, 0xff], [0x1f, 0x23, 0x28])
    } else {
        ([0x0d, 0x11, 0x17], [0xe6, 0xed, 0xf3])
    }
}

fn panel_marks(
    png: &[u8],
    panel: (f64, f64, f64, f64),
    background: [u8; 3],
    foreground: [u8; 3],
) -> String {
    let (width, height, rgba) = decode_png(png).expect("decode panel png");
    let (x0, y0, pw, ph) = panel;
    let dx = pw / width as f64;
    let dy = ph / height as f64;
    // One path per composited color. Runs of the same pixel share a subpath.
    let mut paths: BTreeMap<[u8; 3], String> = BTreeMap::new();
    for y in 0..height {
        let mut x = 0;
        while x < width {
            let Some(color) = composite(pixel_at(&rgba, width, x, y), background, foreground)
            else {
                x += 1;
                continue;
            };
            let start = x;
            x += 1;
            while x < width
                && composite(pixel_at(&rgba, width, x, y), background, foreground) == Some(color)
            {
                x += 1;
            }
            let path = paths.entry(color).or_default();
            push_run(
                path,
                x0 + start as f64 * dx,
                y0 + y as f64 * dy,
                (x - start) as f64 * dx,
                dy,
            );
        }
    }
    let mut out = String::new();
    out.push_str("<g shape-rendering=\"geometricPrecision\">\n");
    for ([r, g, b], path) in paths {
        out.push_str(&format!(
            "<path fill=\"#{r:02x}{g:02x}{b:02x}\" d=\"{path}\"/>\n"
        ));
    }
    out.push_str("</g>\n");
    out
}

fn push_run(path: &mut String, x: f64, y: f64, width: f64, height: f64) {
    use std::fmt::Write as _;
    let _ = write!(
        path,
        "M{} {}h{}v{}h-{}z",
        num(x),
        num(y),
        num(width),
        num(height),
        num(width)
    );
}

/// Straight-alpha coverage over the card. Faint fringe pixels are dropped;
/// the rest become an opaque color so the file needs no `fill-opacity`.
///
/// The pixel raster freezes `Color::Default` to mid-gray. The SVG card
/// paints that same default as the card foreground, and so does this.
fn composite(pixel: [u8; 4], background: [u8; 3], foreground: [u8; 3]) -> Option<[u8; 3]> {
    let [mut r, mut g, mut b, a] = pixel;
    if a < 12 {
        return None;
    }
    if (r, g, b) == (128, 128, 128) {
        [r, g, b] = foreground;
    }
    if a == 255 {
        return Some([r, g, b]);
    }
    let coverage = f64::from(a) / 255.0;
    let mix = |source: u8, dest: u8| {
        (f64::from(source) * coverage + f64::from(dest) * (1.0 - coverage)).round() as u8
    };
    Some([
        mix(r, background[0]),
        mix(g, background[1]),
        mix(b, background[2]),
    ])
}

fn pixel_at(rgba: &[u8], width: usize, x: usize, y: usize) -> [u8; 4] {
    let index = (y * width + x) * 4;
    [
        rgba[index],
        rgba[index + 1],
        rgba[index + 2],
        rgba[index + 3],
    ]
}

fn rect_bounds(line: &str) -> Option<(f64, f64, f64, f64)> {
    Some((
        attr(line, "x").unwrap_or(0.0),
        attr(line, "y").unwrap_or(0.0),
        attr(line, "width")?,
        attr(line, "height")?,
    ))
}

fn text_bounds(line: &str) -> Option<(f64, f64, f64, f64)> {
    Some((
        attr(line, "x")?,
        attr(line, "y")? - BASELINE,
        attr(line, "textLength")?,
        CELL_H,
    ))
}

/// Whether `bounds` lies inside the panel, with a fraction of a pixel of slack.
fn contained(bounds: (f64, f64, f64, f64), panel: (f64, f64, f64, f64)) -> bool {
    const SLACK: f64 = 0.2;
    let (x, y, width, height) = bounds;
    let (px, py, pw, ph) = panel;
    x >= px - SLACK
        && y >= py - SLACK
        && x + width <= px + pw + SLACK
        && y + height <= py + ph + SLACK
}

fn attr(line: &str, name: &str) -> Option<f64> {
    let key = format!("{name}=\"");
    let start = line.find(&key)? + key.len();
    let end = start + line[start..].find('"')?;
    line[start..end].parse().ok()
}

fn extract_png(rendered: &str) -> Option<Vec<u8>> {
    let marker = "\u{1b}]1337;File=";
    let start = rendered.find(marker)?;
    let header = &rendered[start + marker.len()..];
    let colon = header.find(':')?;
    let end = header.find('\u{7}')?;
    if end <= colon {
        return None;
    }
    decode_base64(&header[colon + 1..end])
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    fn value(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let (a, b, c, d) = (chunk[0], chunk[1], chunk[2], chunk[3]);
        let av = value(a)?;
        let bv = value(b)?;
        let cv = if c == b'=' { 0 } else { value(c)? };
        let dv = if d == b'=' { 0 } else { value(d)? };
        let packed =
            (u32::from(av) << 18) | (u32::from(bv) << 12) | (u32::from(cv) << 6) | u32::from(dv);
        out.push((packed >> 16) as u8);
        if c != b'=' {
            out.push((packed >> 8) as u8);
        }
        if d != b'=' {
            out.push(packed as u8);
        }
    }
    Some(out)
}

/// Malevich's panel PNG: RGBA8, filter None, one deflate stream.
fn decode_png(png: &[u8]) -> Result<(usize, usize, Vec<u8>), String> {
    if png.len() < 8 || png[..8] != [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A] {
        return Err("not a png".into());
    }
    let mut index = 8;
    let mut width = 0usize;
    let mut height = 0usize;
    let mut idat = Vec::new();
    while index + 8 <= png.len() {
        let len = u32::from_be_bytes(png[index..index + 4].try_into().unwrap()) as usize;
        let kind = &png[index + 4..index + 8];
        let data_at = index + 8;
        let next = data_at
            .checked_add(len)
            .and_then(|end| end.checked_add(4))
            .ok_or_else(|| "png chunk overruns the file".to_string())?;
        if next > png.len() {
            return Err("png chunk overruns the file".into());
        }
        let data = &png[data_at..data_at + len];
        if kind == b"IHDR" {
            if data.len() < 13 || data[8] != 8 || data[9] != 6 {
                return Err("panel png is not RGBA8".into());
            }
            width = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
            height = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
        } else if kind == b"IDAT" {
            idat.extend_from_slice(data);
        } else if kind == b"IEND" {
            break;
        }
        index = next;
    }
    if width == 0 || height == 0 {
        return Err("png has no image".into());
    }
    let mut raw = Vec::new();
    ZlibDecoder::new(&idat[..])
        .read_to_end(&mut raw)
        .map_err(|error| error.to_string())?;
    let stride = 1 + width * 4;
    if raw.len() != height * stride {
        return Err(format!(
            "inflated {} bytes, expected {}",
            raw.len(),
            height * stride
        ));
    }
    let mut rgba = Vec::with_capacity(width * height * 4);
    for row in raw.chunks(stride) {
        if row[0] != 0 {
            return Err("png row filter is not None".into());
        }
        rgba.extend_from_slice(&row[1..]);
    }
    Ok((width, height, rgba))
}

fn num(value: f64) -> String {
    let mut text = format!("{value:.3}");
    if text.contains('.') {
        while text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
    }
    text
}
