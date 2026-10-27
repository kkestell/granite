//! Independent snapshots and cell-level diagnostics .
//! Reading a fresh render state consumes dirty flags: never snapshot the mux's terminal.
use libghostty_vt::error::Result;
use libghostty_vt::render::{CellIterator, Colors, CursorVisualStyle, RowIterator};
use libghostty_vt::screen::{CellContentTag, CellWide};
use libghostty_vt::style::{RgbColor, Style, StyleColor};
use libghostty_vt::terminal::{Mode, ModeKind};
use libghostty_vt::{RenderState, Terminal};
use std::fmt::Write as _;

pub const COMPARED_MODES: [u16; 19] = [
    1, 5, 9, 66, 67, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 2004,
    2027,
];
#[derive(Debug, PartialEq, Eq)]
pub enum Width {
    Narrow,
    Wide,
    Tail,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Cell {
    pub text: Vec<char>,
    pub wide: Width,
    // Colors in style are normalized away, leaving only its attribute flags.
    pub flags: Style,
    pub fg: RgbColor,
    pub bg: RgbColor,
    pub underline_color: Option<RgbColor>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Cursor {
    pos: Option<(u16, u16)>,
    visible: bool,
    style: CursorVisualStyle,
    blinking: bool,
}
#[derive(Debug)]
pub struct Snapshot {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<Cell>,
    pub cursor: Cursor,
    pub modes: Vec<bool>,
    pub kitty_flags: u8,
}
fn resolve(color: StyleColor, colors: &Colors) -> Option<RgbColor> {
    match color {
        StyleColor::None => None,
        StyleColor::Palette(i) => Some(colors.palette[i.0 as usize]),
        StyleColor::Rgb(c) => Some(c),
    }
}
pub fn take(t: &Terminal) -> Result<Snapshot> {
    let mut state = RenderState::new()?;
    let snapshot = state.update(t)?;
    let colors = snapshot.colors()?;
    let mut cells = Vec::new();
    let mut row_iter = RowIterator::new()?;
    let mut cell_iter = CellIterator::new()?;
    let mut rows = row_iter.update(&snapshot)?;
    while let Some(row) = rows.next() {
        let mut row_cells = cell_iter.update(row)?;
        while let Some(cell) = row_cells.next() {
            let raw = cell.raw_cell()?;
            let mut style = if raw.has_styling()? {
                cell.style()?
            } else {
                Style::default()
            };
            match raw.content_tag()? {
                CellContentTag::BgColorPalette => {
                    style.bg_color = StyleColor::Palette(raw.bg_color_palette()?)
                }
                CellContentTag::BgColorRgb => style.bg_color = StyleColor::Rgb(raw.bg_color_rgb()?),
                _ => {}
            }
            let fg = resolve(style.fg_color, &colors).unwrap_or(colors.foreground);
            let bg = resolve(style.bg_color, &colors).unwrap_or(colors.background);
            let underline_color = resolve(style.underline_color, &colors);
            style.fg_color = StyleColor::None;
            style.bg_color = StyleColor::None;
            style.underline_color = StyleColor::None;
            let mut text = cell.graphemes()?;
            if text == [' '] {
                text.clear();
            }
            cells.push(Cell {
                text,
                wide: match raw.wide()? {
                    CellWide::Wide => Width::Wide,
                    CellWide::SpacerTail => Width::Tail,
                    _ => Width::Narrow,
                },
                flags: style,
                fg,
                bg,
                underline_color,
            });
        }
    }
    let c = snapshot.cursor()?;
    Ok(Snapshot {
        cols: snapshot.cols()?,
        rows: snapshot.rows()?,
        cells,
        cursor: Cursor {
            pos: c.viewport.map(|p| (p.x, p.y)),
            visible: c.visible,
            style: c.visual_style,
            blinking: c.blinking,
        },
        modes: COMPARED_MODES
            .iter()
            .map(|&v| t.mode(Mode::new(v, ModeKind::Dec)))
            .collect::<Result<_>>()?,
        kitty_flags: t.kitty_keyboard_flags()?.bits(),
    })
}
impl Snapshot {
    pub fn dump(&self) -> String {
        let mut out = String::new();
        for row in self.cells.chunks(self.cols as usize) {
            out.push_str("    |");
            for cell in row {
                if cell.wide == Width::Tail {
                    continue;
                }
                if cell.text.is_empty() {
                    out.push(' ');
                } else {
                    out.extend(&cell.text);
                }
            }
            out.push_str("|\n");
        }
        out
    }
    pub fn diff(&self, other: &Self, max_cells: usize) -> String {
        let mut out = String::new();
        if (self.cols, self.rows) != (other.cols, other.rows) {
            return format!(
                "  size: granite {}x{}, host {}x{}\n",
                self.cols, self.rows, other.cols, other.rows
            );
        }
        if self.cursor != other.cursor {
            writeln!(
                out,
                "  cursor: granite {:?}, host {:?}",
                self.cursor, other.cursor
            )
            .unwrap();
        }
        for ((&value, &a), &b) in COMPARED_MODES.iter().zip(&self.modes).zip(&other.modes) {
            if a != b {
                writeln!(out, "  mode {value}: granite {a}, host {b}").unwrap();
            }
        }
        if self.kitty_flags != other.kitty_flags {
            writeln!(
                out,
                "  kitty keyboard flags: granite {}, host {}",
                self.kitty_flags, other.kitty_flags
            )
            .unwrap();
        }
        let mut shown = 0;
        for (i, (a, b)) in self.cells.iter().zip(&other.cells).enumerate() {
            if a == b {
                continue;
            }
            shown += 1;
            if shown <= max_cells {
                writeln!(
                    out,
                    "  row {} col {}:\n    granite {a:?}\n    host    {b:?}",
                    i / self.cols as usize,
                    i % self.cols as usize
                )
                .unwrap();
            }
        }
        if shown > max_cells {
            writeln!(out, "  ... and {} more cells", shown - max_cells).unwrap();
        }
        out
    }
}
