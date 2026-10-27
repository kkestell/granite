//! Hand-written round-trip cases.
use granite::recording::{Record, Size};
pub struct Fixture {
    pub name: &'static str,
    pub cols: u16,
    pub rows: u16,
    pub records: &'static [Record<'static>],
    pub known: Option<&'static str>,
}
const fn o(data: &'static [u8]) -> Record<'static> {
    Record::Output(data)
}
const fn size(cols: u16, rows: u16) -> Record<'static> {
    Record::Size(Size { cols, rows })
}
const NUMBERED: &[u8] = b"1111\r\n2222\r\n3333\r\n4444\r\n5555\r\n6666\r\n7777\r\n8888";
pub const ALL: &[Fixture] = &[
    Fixture { name: "plain text", cols: 20, rows: 8, records: &[ o(b"hello"), o(b"\r\nworld\r\n"), o(b"third line") ], known: None },
    Fixture { name: "ED with palette bg", cols: 20, rows: 8, records: &[ o(NUMBERED), o(b"\x1b[44m\x1b[2J"), o(b"\x1b[3;3Hx\x1b[0m") ], known: None },
    Fixture { name: "ED below and above with bg", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[4;3H\x1b[41m\x1b[J"),
        o(b"\x1b[2;2H\x1b[48;5;202m\x1b[1J\x1b[0m"),
    ], known: None },
    Fixture { name: "EL with rgb bg", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[2;3H\x1b[48;2;10;20;30m\x1b[K"),
        o(b"\x1b[3;3H\x1b[48;5;33m\x1b[1K"),
        o(b"\x1b[4;3H\x1b[42m\x1b[2K\x1b[0m"),
    ], known: None },
    Fixture { name: "ECH with bg", cols: 20, rows: 8, records: &[ o(b"hello world"), o(b"\x1b[1;3H\x1b[45m\x1b[4X\x1b[0m") ], known: None },
    Fixture { name: "erase with fg, underline, and inverse", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[2;2H\x1b[4;31;43m\x1b[K"),
        o(b"\x1b[3;2H\x1b[7;32m\x1b[K\x1b[0m"),
        o(b"\x1b[5;1H\x1b[38;2;1;2;3;48;2;200;100;50m\x1b[J\x1b[0m"),
    ], known: None },
    Fixture { name: "DECSTBM with SU and SD", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[3;6r"),
        o(b"\x1b[2S"),
        o(b"\x1b[44m\x1b[T\x1b[0m"),
        o(b"\x1b[r\x1b[8;1H"),
    ], known: None },
    Fixture { name: "DECSTBM with IL and DL", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[2;7r\x1b[3;1H\x1b[2L"),
        o(b"\x1b[5;1H\x1b[43m\x1b[M\x1b[0m"),
        o(b"\x1b[r"),
    ], known: None },
    Fixture { name: "linefeed at bottom margin", cols: 20, rows: 8, records: &[
        o(NUMBERED),
        o(b"\x1b[2;5r\x1b[5;1H\nnew\nlines"),
        o(b"\x1b[2;1H\x1bMup\x1bMup"),
        o(b"\x1b[r"),
    ], known: None },
    Fixture { name: "scrolling past the screen", cols: 20, rows: 8, records: &[
        o(b"a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni\r\nj\r\nk\r\nl\r\nm"),
        o(b"\r\nn\r\no\r\n\x1b[41mp\x1b[0m"),
    ], known: None },
    Fixture { name: "ICH and DCH", cols: 20, rows: 8, records: &[
        o(b"abcdefghijklmnopqrst"),
        o(b"\x1b[1;3H\x1b[2@"),
        o(b"\x1b[1;8H\x1b[3P"),
        o(b"\x1b[2;1Hwide\xe4\xb8\xad\xe6\x96\x87end\x1b[2;3H\x1b[1P"),
    ], known: None },
    Fixture { name: "insert mode", cols: 20, rows: 8, records: &[ o(b"abcdef\r"), o(b"\x1b[4hXY\x1b[4l") ], known: None },
    Fixture { name: "alt screen 1049", cols: 20, rows: 8, records: &[
        o(b"primary\r\nscreen"),
        o(b"\x1b[?1049h"),
        o(b"\x1b[44malt\x1b[0m"),
        o(b"\x1b[?1049l"),
    ], known: None },
    Fixture { name: "alt screen 47 and 1047", cols: 20, rows: 8, records: &[
        o(b"primary"),
        o(b"\x1b[?47hforty-seven"),
        o(b"\x1b[?47l\x1b[?1047hten-forty-seven"),
        o(b"\x1b[?1047l"),
    ], known: None },
    Fixture { name: "cursor save across alt screen", cols: 20, rows: 8, records: &[
        o(b"\x1b[3;5H\x1b7\x1b[?1049h\x1b[6;6Hx"),
        o(b"\x1b[?1049l\x1b8y"),
    ], known: None },
    Fixture { name: "wide characters", cols: 20, rows: 8, records: &[o(b"\xe4\xb8\xad\xe6\x96\x87 text \xf0\x9f\x98\x80")], known: None },
    Fixture { name: "wide character at the right margin", cols: 20, rows: 8, records: &[
        o(b"0123456789012345678"),
        o(b"\xe4\xb8\xad"),
        o(b"after"),
    ], known: None },
    Fixture { name: "wide character without wraparound", cols: 20, rows: 8, records: &[
        o(b"\x1b[?7l0123456789012345678"),
        o(b"\xe4\xb8\xad"),
        o(b"\x1b[?7h"),
    ], known: None },
    Fixture { name: "wide character overwritten", cols: 20, rows: 8, records: &[
        o(b"\xe4\xb8\xad\xe6\x96\x87"),
        o(b"\x1b[1;2Hx"),
        o(b"\x1b[1;3H\x1b[41my\x1b[0m"),
    ], known: None },
    Fixture { name: "combining marks", cols: 20, rows: 8, records: &[o(b"e\xcc\x81 a\xcc\x88\xcc\xa3 n\xcc\x83")], known: None },
    Fixture { name: "combining marks without grapheme clustering", cols: 20, rows: 8, records: &[
        o(b"\x1b[?2027le\xcc\x81 a\xcc\x88\xcc\xa3 n\xcc\x83"),
    ], known: None },
    Fixture { name: "combining mark at the right margin", cols: 20, rows: 8, records: &[
        o(b"0123456789012345678e"),
        o(b"\xcc\x81"),
        o(b"next"),
    ], known: None },
    Fixture { name: "combining mark at the right margin without grapheme clustering", cols: 20, rows: 8, records: &[
        o(b"\x1b[?2027l0123456789012345678e"),
        o(b"\xcc\x81"),
        o(b"next"),
    ], known: None },
    Fixture { name: "combining mark after moving back to an earlier row", cols: 20, rows: 8, records: &[
        o(b"\x1b[?2027le\r\nnext"),
        o(b"\x1b[1;2H\xcc\x81\x1b[2;5H"),
    ], known: None },
    Fixture { name: "emoji with variation selector", cols: 20, rows: 8, records: &[o(b"\xe2\x9d\xa4\xef\xb8\x8f x \xe2\x9c\x94\xef\xb8\x8e y")], known: None },
    Fixture { name: "emoji with variation selector without grapheme clustering", cols: 20, rows: 8, records: &[
        o(b"\x1b[?2027l\xe2\x9d\xa4\xef\xb8\x8f x \xe2\x9c\x94\xef\xb8\x8e y"),
    ], known: None },
    Fixture { name: "ZWJ sequence with grapheme clustering", cols: 20, rows: 8, records: &[
        o(b"\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 family"),
        o(b"\r\n\xf0\x9f\x87\xba\xf0\x9f\x87\xb8 flag"),
    ], known: None },
    Fixture { name: "ZWJ sequence without grapheme clustering", cols: 20, rows: 8, records: &[
        o(b"\x1b[?2027l\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9 x"),
    ], known: None },
    Fixture { name: "cluster ending in ZWJ next to a pictograph", cols: 20, rows: 8, records: &[o(b"\x1b[1;3H\xe2\x9d\xa4\x1b[1;1H\xf0\x9f\x91\xa8\xe2\x80\x8d")], known: Some("the host joins a cell to the cluster on its left when they would form one grapheme") },
    Fixture { name: "lone regional indicator next to a flag", cols: 20, rows: 8, records: &[o(b"\x1b[1;3H\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\x1b[1;1H\xf0\x9f\x87\xba")], known: Some("the host joins a cell to the cluster on its left when they would form one grapheme") },
    Fixture { name: "row printed in both grapheme clustering modes", cols: 20, rows: 8, records: &[ o(b"\x1b[?2027l\xe2\x9d\xa4\xef\xb8\x8f"), o(b"\x1b[?2027h x") ], known: Some("the host lays out a whole row in one grapheme clustering mode") },
    Fixture { name: "soft-wrapped lines", cols: 20, rows: 8, records: &[
        o(b"This line is long enough to wrap twice in twenty columns."),
        o(b"\r\nshort"),
    ], known: None },
    Fixture { name: "pending wrap cursor", cols: 20, rows: 8, records: &[o(b"01234567890123456789")], known: None },
    Fixture { name: "reflow on resize", cols: 20, rows: 8, records: &[
        o(b"This line is long enough to wrap twice.\r\n\x1b[42mgreen\x1b[0m"),
        size(30, 6),
        o(b"x"),
        size(12, 10),
    ], known: None },
    Fixture { name: "resize to the same size", cols: 20, rows: 8, records: &[ o(b"text \x1b[41mred\x1b[0m"), size(20, 8) ], known: None },
    Fixture { name: "resize on the alt screen", cols: 20, rows: 8, records: &[
        o(b"\x1b[?1049h\x1b[44m\x1b[2Jblue"),
        size(25, 5),
        o(b"\x1b[5;25Hz"),
    ], known: None },
    Fixture { name: "ANSI colors", cols: 20, rows: 8, records: &[
        o(b"\x1b[30ma\x1b[31mb\x1b[32mc\x1b[33md\x1b[34me\x1b[35mf\x1b[36mg\x1b[37mh"),
        o(b"\x1b[90ma\x1b[91mb\x1b[92mc\x1b[93md\x1b[94me\x1b[95mf\x1b[96mg\x1b[97mh\x1b[39m"),
        o(b"\r\n\x1b[40ma\x1b[41mb\x1b[42mc\x1b[43md\x1b[100me\x1b[107mf\x1b[49m"),
    ], known: None },
    Fixture { name: "256 and RGB colors", cols: 20, rows: 8, records: &[
        o(b"\x1b[38;5;16ma\x1b[38;5;231mb\x1b[38;5;196mc\x1b[48;5;21md\x1b[48;5;244me\x1b[0m"),
        o(b"\r\n\x1b[38;2;255;128;0ma\x1b[48;2;0;64;128mb\x1b[38:2::1:2:3mc\x1b[48:5:99md\x1b[0m"),
        o(b"\r\n\x1b[38;5;3mpalette\x1b[38;2;205;205;0m rgb\x1b[0m"),
    ], known: None },
    Fixture { name: "attributes", cols: 20, rows: 8, records: &[
        o(b"\x1b[1mb\x1b[2mf\x1b[22m\x1b[3mi\x1b[23m\x1b[5mk\x1b[25m\x1b[7mr\x1b[27m"),
        o(b"\x1b[8mh\x1b[28m\x1b[9ms\x1b[29m\x1b[53mo\x1b[55m\x1b[1;2;3mall\x1b[0m"),
    ], known: None },
    Fixture { name: "underline styles and colors", cols: 20, rows: 8, records: &[
        o(b"\x1b[4ma\x1b[4:2mb\x1b[4:3mc\x1b[4:4md\x1b[4:5me\x1b[21mf\x1b[24m"),
        o(b"\r\n\x1b[4;58;5;196ma\x1b[58:2::0:255:0mb\x1b[58;2;0;0;255mc\x1b[59md\x1b[0m"),
        o(b"\r\n\x1b[4:3;58;5;2;41m  \x1b[0m"),
    ], known: None },
    Fixture { name: "styled blank cells", cols: 20, rows: 8, records: &[o(b"\x1b[7m   \x1b[0m \x1b[4m   \x1b[9;41m \x1b[0m")], known: None },
    Fixture { name: "cursor shapes", cols: 20, rows: 8, records: &[
        o(b"\x1b[5 q"),
        o(b"\x1b[6 q"),
        o(b"\x1b[3 q"),
        o(b"\x1b[4 q"),
        o(b"\x1b[1 q"),
        o(b"\x1b[0 q"),
        o(b"\x1b[?12h"),
        o(b"\x1b[?12l"),
    ], known: None },
    Fixture { name: "cursor visibility", cols: 20, rows: 8, records: &[ o(b"\x1b[?25l"), o(b"\x1b[3;3H"), o(b"\x1b[?25h") ], known: None },
    Fixture { name: "cursor movement", cols: 20, rows: 8, records: &[
        o(b"\x1b[5;10H"),
        o(b"\x1b[2A\x1b[3D"),
        o(b"\x1b[10G\x1b[2d"),
        o(b"\x1b[99;99H"),
        o(b"\x1bE\x1bD"),
    ], known: None },
    Fixture { name: "origin mode", cols: 20, rows: 8, records: &[ o(b"\x1b[3;6r\x1b[?6h\x1b[1;1Hx\x1b[9;1Hy"), o(b"\x1b[?6l\x1b[r") ], known: None },
    Fixture { name: "tabs", cols: 20, rows: 8, records: &[
        o(b"a\tb\tc"),
        o(b"\r\n\x1b[5G\x1bH\r\tx\x1b[g"),
        o(b"\r\n\x1b[3g\ty\x1b[Zz"),
    ], known: None },
    Fixture { name: "repeat and DECALN", cols: 20, rows: 8, records: &[ o(b"ab\x1b[5b"), o(b"\x1b#8"), o(b"\x1b[3;3Hx") ], known: None },
    Fixture { name: "mirrored input modes", cols: 20, rows: 8, records: &[
        o(b"\x1b[?1h"),
        o(b"\x1b[?1000h\x1b[?1006h"),
        o(b"\x1b[?1002h\x1b[?1003h\x1b[?1004h\x1b[?2004h"),
        o(b"\x1b[?1l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?2004l"),
    ], known: None },
    Fixture { name: "other input modes", cols: 20, rows: 8, records: &[
        o(b"\x1b[?9h"),
        o(b"\x1b="),
        o(b"\x1b>\x1b[?66h\x1b[?67h"),
        o(b"\x1b[?1000h\x1b[?1005h"),
        o(b"\x1b[?1005l\x1b[?1015h"),
        o(b"\x1b[?1015l\x1b[?1016h"),
        o(b"\x1b[?1007l\x1b[?1036l\x1b[?1039h\x1b[?1035l"),
    ], known: None },
    Fixture { name: "kitty keyboard flags", cols: 20, rows: 8, records: &[
        o(b"\x1b[>1u"),
        o(b"\x1b[>15u"),
        o(b"\x1b[=3;2u"),
        o(b"\x1b[<u"),
        o(b"\x1b[?1049h\x1b[>5u"),
        o(b"\x1b[?1049l"),
    ], known: None },
    Fixture { name: "reverse video", cols: 20, rows: 8, records: &[ o(b"text \x1b[41mred\x1b[0m"), o(b"\x1b[?5h"), o(b"more") ], known: None },
    Fixture { name: "synchronized output", cols: 20, rows: 8, records: &[
        o(b"before"),
        o(b"\x1b[?2026h\x1b[2J\x1b[Hduring"),
        o(b" still"),
        o(b"\x1b[?2026l"),
    ], known: None },
    Fixture { name: "reset", cols: 20, rows: 8, records: &[
        o(b"\x1b[?1h\x1b[?2004h\x1b[5 q\x1b[41mtext"),
        o(b"\x1bc"),
        o(b"after"),
    ], known: None },
    Fixture { name: "title, bell, and hyperlink", cols: 20, rows: 8, records: &[
        o(b"\x1b]2;title\x07\x07"),
        o(b"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ text"),
    ], known: None },
    Fixture { name: "OSC 4 palette change", cols: 20, rows: 8, records: &[ o(b"\x1b[31mred"), o(b"\x1b]4;1;rgb:12/34/56\x1b\\") ], known: Some("granite doesn't forward palette changes to the host") },
    Fixture { name: "OSC 10 and 11 default colors", cols: 20, rows: 8, records: &[ o(b"text"), o(b"\x1b]10;rgb:ff/00/00\x07\x1b]11;#000080\x07") ], known: Some("granite doesn't forward default color changes to the host") },
];
