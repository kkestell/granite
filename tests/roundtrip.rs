//! Program output -> mux -> stand-in host terminal, compared after every frame.
//! Port of zig/test/roundtrip.zig; the twin avoids consuming mux dirty flags.
#[path = "support/fixtures.rs"]
mod fixtures;
#[path = "support/fuzz.rs"]
mod fuzz;
#[path = "support/screen.rs"]
mod screen;
use granite::{
    mux::{self, Mux, Winsize},
    recording::{Reader, Record, Size},
};
use libghostty_vt::Terminal;

#[derive(Clone, Debug)]
pub enum Input {
    Output(Vec<u8>),
    Size(Size),
}
impl From<Record<'_>> for Input {
    fn from(r: Record<'_>) -> Self {
        match r {
            Record::Output(b) => Self::Output(b.to_vec()),
            Record::Size(s) => Self::Size(s),
        }
    }
}
fn host_replies() -> Vec<u8> {
    let mut r = String::from("\x1b]10;rgb:d0d0/d1d1/d2d2\x1b\\\x1b]11;rgb:1010/1111/1212\x1b\\");
    for i in 0..16 {
        r.push_str(&format!(
            "\x1b]4;{i};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
            i * 16 + 1,
            255 - i * 15,
            i * 7 + 3
        ));
    }
    r.push_str("\x1b[?2027;1$y\x1b[?62;22c");
    r.into_bytes()
}
fn winsize(s: Size) -> Winsize {
    Winsize {
        ws_col: s.cols,
        ws_row: s.rows,
        ws_xpixel: s.cols * 8,
        ws_ypixel: s.rows * 16,
    }
}
fn term(s: Size, replies: &[u8]) -> Terminal<'static, 'static> {
    let mut t = Terminal::new(s.cols, s.rows).unwrap();
    mux::use_host_replies_for(&mut t, replies).unwrap();
    t
}
fn frame(m: &mut Mux, twin: &Terminal, host: &mut Terminal) -> Option<String> {
    m.render().unwrap();
    host.vt_write(&m.take_output());
    let want = screen::take(twin).unwrap();
    let got = screen::take(host).unwrap();
    let diff = want.diff(&got, 12);
    if diff.is_empty() {
        None
    } else {
        Some(format!(
            "{diff}  program screen:\n{}  host screen:\n{}",
            want.dump(),
            got.dump()
        ))
    }
}
fn escaped(bytes: &[u8]) -> String {
    let mut out = String::from("\"");
    for &b in bytes.iter().take(160) {
        match b {
            0x1b => out.push_str("\\e"),
            b'\r' => out.push_str("\\r"),
            b'\n' => out.push_str("\\n"),
            b'"' | b'\\' => {
                out.push('\\');
                out.push(b as char);
            }
            0x20..=0x7e => out.push(b as char),
            _ => out.push_str(&format!("\\x{b:02x}")),
        }
    }
    out.push('"');
    out
}
fn round_trip(label: &str, initial: Size, records: &[Input]) -> Option<String> {
    let replies = host_replies();
    let mut m = Mux::new(winsize(initial), &["test"]).unwrap();
    m.use_host_replies(&replies).unwrap();
    let mut twin = term(initial, &replies);
    let mut host = term(initial, &replies);
    host.vt_write(b"\x1b[?1049h\x1b[2J");
    for (i, r) in records.iter().enumerate() {
        match r {
            Input::Output(data) => {
                m.panes[0].feed(data);
                twin.vt_write(data);
            }
            Input::Size(s) => {
                host.resize(s.cols, s.rows, 0, 0).unwrap();
                twin.resize(s.cols, s.rows, 0, 0).unwrap();
                m.resize(winsize(*s)).unwrap();
            }
        }
        if m.panes[0].held() {
            continue;
        }
        if let Some(diff) = frame(&mut m, &twin, &mut host) {
            let record = match r {
                Input::Output(b) => escaped(b),
                Input::Size(s) => format!("size {}x{}", s.cols, s.rows),
            };
            return Some(format!(
                "{label}: after record {} of {}: {record}\n{diff}",
                i + 1,
                records.len()
            ));
        }
    }
    m.panes[0].set_held(false);
    frame(&mut m, &twin, &mut host).map(|diff| format!("{label}: after the final frame\n{diff}"))
}
/// Merge output between resizes, then randomly split it. Matches Zig's PRNG and widths.
fn split(records: &[Input], seed: u64) -> Vec<Input> {
    let mut r = fuzz::Random::new(seed);
    let mut result = Vec::new();
    let mut pending = Vec::new();
    for (i, record) in records.iter().enumerate() {
        match record {
            Input::Output(b) => pending.extend_from_slice(b),
            Input::Size(s) => result.push(Input::Size(*s)),
        }
        let last = i + 1 == records.len() || matches!(records[i + 1], Input::Size(_));
        if matches!(record, Input::Output(_)) && last {
            let maxes = [1, 2, 7, 32, 256];
            let max = maxes[r.less(64, maxes.len() as u64) as usize];
            let mut rest = pending.as_slice();
            while !rest.is_empty() {
                let n = rest.len().min(r.range(64, 1, max) as usize);
                result.push(Input::Output(rest[..n].to_vec()));
                rest = &rest[n..];
            }
            pending.clear();
        }
    }
    result
}
fn round_trip_splits(name: &str, initial: Size, records: &[Input], splits: u64) -> Option<String> {
    if let Some(diff) = round_trip(name, initial, records) {
        return Some(diff);
    }
    for seed in 1..=splits {
        let label = format!("{name} (split seed {seed})");
        if let Some(diff) = round_trip(&label, initial, &split(records, seed)) {
            return Some(diff);
        }
    }
    None
}
fn fixture(index: usize) {
    let f = &fixtures::ALL[index];
    let records: Vec<_> = f.records.iter().copied().map(Input::from).collect();
    let result = round_trip_splits(
        f.name,
        Size {
            cols: f.cols,
            rows: f.rows,
        },
        &records,
        8,
    );
    if let Some(why) = f.known {
        assert!(
            result.is_some(),
            "{}: matches, but is marked as a known gap ({why})",
            f.name
        );
    } else if let Some(diff) = result {
        panic!("{diff}");
    }
}
fn env_u64(name: &str, default: u64) -> u64 {
    match std::env::var(name) {
        Ok(s) => s
            .parse()
            .unwrap_or_else(|_| panic!("{name} must be an unsigned integer")),
        Err(std::env::VarError::NotPresent) => default,
        Err(e) => panic!("{name}: {e}"),
    }
}
#[test]
fn fuzz() {
    let iterations = env_u64("GRANITE_FUZZ_ITERATIONS", 300);
    let first = env_u64("GRANITE_FUZZ_SEED", 1);
    for i in 0..iterations {
        let seed = first.wrapping_add(i);
        let mut r = fuzz::Random::new(seed);
        let initial = Size {
            cols: r.range(16, 4, 60) as u16,
            rows: r.range(16, 2, 20) as u16,
        };
        let records = fuzz::generate(&mut r);
        if let Some(diff) = round_trip_splits(&format!("fuzz seed {seed}"), initial, &records, 2) {
            panic!("{diff}");
        }
    }
}
fn recording(name: &str) {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("zig/test/recordings")
        .join(name);
    let data = std::fs::read(&path).unwrap();
    let mut reader = Reader::new(&data).unwrap();
    let initial = match reader.next().unwrap() {
        Some(Record::Size(s)) if s.cols > 0 && s.rows > 0 => s,
        _ => panic!("{name}: doesn't start with a usable size"),
    };
    let mut records = Vec::new();
    while let Some(r) = reader.next().unwrap() {
        records.push(Input::from(r));
    }
    if let Some(diff) = round_trip_splits(name, initial, &records, 2) {
        panic!("{diff}");
    }
}

mod fixtures_tests {
    use super::fixture;
    #[test]
    fn plain_text() {
        fixture(0);
    }
    #[test]
    fn ed_with_palette_bg() {
        fixture(1);
    }
    #[test]
    fn ed_below_and_above_with_bg() {
        fixture(2);
    }
    #[test]
    fn el_with_rgb_bg() {
        fixture(3);
    }
    #[test]
    fn ech_with_bg() {
        fixture(4);
    }
    #[test]
    fn erase_with_fg_underline_and_inverse() {
        fixture(5);
    }
    #[test]
    fn decstbm_with_su_and_sd() {
        fixture(6);
    }
    #[test]
    fn decstbm_with_il_and_dl() {
        fixture(7);
    }
    #[test]
    fn linefeed_at_bottom_margin() {
        fixture(8);
    }
    #[test]
    fn scrolling_past_the_screen() {
        fixture(9);
    }
    #[test]
    fn ich_and_dch() {
        fixture(10);
    }
    #[test]
    fn insert_mode() {
        fixture(11);
    }
    #[test]
    fn alt_screen_1049() {
        fixture(12);
    }
    #[test]
    fn alt_screen_47_and_1047() {
        fixture(13);
    }
    #[test]
    fn cursor_save_across_alt_screen() {
        fixture(14);
    }
    #[test]
    fn wide_characters() {
        fixture(15);
    }
    #[test]
    fn wide_character_at_the_right_margin() {
        fixture(16);
    }
    #[test]
    fn wide_character_without_wraparound() {
        fixture(17);
    }
    #[test]
    fn wide_character_overwritten() {
        fixture(18);
    }
    #[test]
    fn combining_marks() {
        fixture(19);
    }
    #[test]
    fn combining_marks_without_grapheme_clustering() {
        fixture(20);
    }
    #[test]
    fn combining_mark_at_the_right_margin() {
        fixture(21);
    }
    #[test]
    fn combining_mark_at_the_right_margin_without_grapheme_clustering() {
        fixture(22);
    }
    #[test]
    fn combining_mark_after_moving_back_to_an_earlier_row() {
        fixture(23);
    }
    #[test]
    fn emoji_with_variation_selector() {
        fixture(24);
    }
    #[test]
    fn emoji_with_variation_selector_without_grapheme_clustering() {
        fixture(25);
    }
    #[test]
    fn zwj_sequence_with_grapheme_clustering() {
        fixture(26);
    }
    #[test]
    fn zwj_sequence_without_grapheme_clustering() {
        fixture(27);
    }
    #[test]
    fn cluster_ending_in_zwj_next_to_a_pictograph() {
        fixture(28);
    }
    #[test]
    fn lone_regional_indicator_next_to_a_flag() {
        fixture(29);
    }
    #[test]
    fn row_printed_in_both_grapheme_clustering_modes() {
        fixture(30);
    }
    #[test]
    fn soft_wrapped_lines() {
        fixture(31);
    }
    #[test]
    fn pending_wrap_cursor() {
        fixture(32);
    }
    #[test]
    fn reflow_on_resize() {
        fixture(33);
    }
    #[test]
    fn resize_to_the_same_size() {
        fixture(34);
    }
    #[test]
    fn resize_on_the_alt_screen() {
        fixture(35);
    }
    #[test]
    fn ansi_colors() {
        fixture(36);
    }
    #[test]
    fn colors_256_and_rgb() {
        fixture(37);
    }
    #[test]
    fn attributes() {
        fixture(38);
    }
    #[test]
    fn underline_styles_and_colors() {
        fixture(39);
    }
    #[test]
    fn styled_blank_cells() {
        fixture(40);
    }
    #[test]
    fn cursor_shapes() {
        fixture(41);
    }
    #[test]
    fn cursor_visibility() {
        fixture(42);
    }
    #[test]
    fn cursor_movement() {
        fixture(43);
    }
    #[test]
    fn origin_mode() {
        fixture(44);
    }
    #[test]
    fn tabs() {
        fixture(45);
    }
    #[test]
    fn repeat_and_decaln() {
        fixture(46);
    }
    #[test]
    fn mirrored_input_modes() {
        fixture(47);
    }
    #[test]
    fn other_input_modes() {
        fixture(48);
    }
    #[test]
    fn kitty_keyboard_flags() {
        fixture(49);
    }
    #[test]
    fn reverse_video() {
        fixture(50);
    }
    #[test]
    fn synchronized_output() {
        fixture(51);
    }
    #[test]
    fn reset() {
        fixture(52);
    }
    #[test]
    fn title_bell_and_hyperlink() {
        fixture(53);
    }
    #[test]
    fn osc_4_palette_change() {
        fixture(54);
    }
    #[test]
    fn osc_10_and_11_default_colors() {
        fixture(55);
    }
}

#[test]
fn recordings() {
    // Discover inputs rather than maintaining a list, so new captures are replayed too.
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("zig/test/recordings");
    let mut names = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file()
            && entry.path().extension().is_some_and(|ext| ext == "rec")
        {
            names.push(entry.file_name().into_string().unwrap());
        }
    }
    names.sort();
    for name in names {
        recording(&name);
    }
}

// Additional regression identified during port review: a same-size resize
// redraws the stale render-state cache instead of the live grapheme cell.
#[test]
#[ignore = "Rust mux loses a non-clustering combining mark on same-size resize"]
fn combining_mark_survives_same_size_resize() {
    let initial = Size { cols: 20, rows: 8 };
    let records = [
        Input::Output(b"\x1b[?2027le".to_vec()),
        Input::Output(b"\xcc\x81".to_vec()),
        Input::Size(initial),
    ];
    if let Some(diff) = round_trip("combining mark then same-size resize", initial, &records) {
        panic!("{diff}");
    }
}
