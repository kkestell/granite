//! Hand-written inputs for the round-trip test. Each fixture is a list of
//! program output chunks and size changes; the test renders a frame after
//! every chunk.

const Record = @import("recording").Record;

pub const Fixture = struct {
    name: []const u8,
    cols: u16 = 20,
    rows: u16 = 8,
    records: []const Record,
    /// Why granite's output is expected to differ from the program's
    /// screen, for fixtures that exercise a known gap.
    known: ?[]const u8 = null,
};

fn o(comptime data: []const u8) Record {
    return .{ .output = data };
}

fn size(cols: u16, rows: u16) Record {
    return .{ .size = .{ .cols = cols, .rows = rows } };
}

/// Fill rows 1 through 8 with a digit each.
const numbered = "1111\r\n2222\r\n3333\r\n4444\r\n5555\r\n6666\r\n7777\r\n8888";

pub const all = [_]Fixture{
    .{ .name = "plain text", .records = &.{ o("hello"), o("\r\nworld\r\n"), o("third line") } },

    // Erasing
    .{ .name = "ED with palette bg", .records = &.{ o(numbered), o("\x1b[44m\x1b[2J"), o("\x1b[3;3Hx\x1b[0m") } },
    .{ .name = "ED below and above with bg", .records = &.{
        o(numbered),
        o("\x1b[4;3H\x1b[41m\x1b[J"),
        o("\x1b[2;2H\x1b[48;5;202m\x1b[1J\x1b[0m"),
    } },
    .{ .name = "EL with rgb bg", .records = &.{
        o(numbered),
        o("\x1b[2;3H\x1b[48;2;10;20;30m\x1b[K"),
        o("\x1b[3;3H\x1b[48;5;33m\x1b[1K"),
        o("\x1b[4;3H\x1b[42m\x1b[2K\x1b[0m"),
    } },
    .{ .name = "ECH with bg", .records = &.{ o("hello world"), o("\x1b[1;3H\x1b[45m\x1b[4X\x1b[0m") } },
    .{ .name = "erase with fg, underline, and inverse", .records = &.{
        o(numbered),
        o("\x1b[2;2H\x1b[4;31;43m\x1b[K"),
        o("\x1b[3;2H\x1b[7;32m\x1b[K\x1b[0m"),
        o("\x1b[5;1H\x1b[38;2;1;2;3;48;2;200;100;50m\x1b[J\x1b[0m"),
    } },

    // Scrolling
    .{ .name = "DECSTBM with SU and SD", .records = &.{
        o(numbered),
        o("\x1b[3;6r"),
        o("\x1b[2S"),
        o("\x1b[44m\x1b[T\x1b[0m"),
        o("\x1b[r\x1b[8;1H"),
    } },
    .{ .name = "DECSTBM with IL and DL", .records = &.{
        o(numbered),
        o("\x1b[2;7r\x1b[3;1H\x1b[2L"),
        o("\x1b[5;1H\x1b[43m\x1b[M\x1b[0m"),
        o("\x1b[r"),
    } },
    .{ .name = "linefeed at bottom margin", .records = &.{
        o(numbered),
        o("\x1b[2;5r\x1b[5;1H\nnew\nlines"),
        o("\x1b[2;1H\x1bMup\x1bMup"),
        o("\x1b[r"),
    } },
    .{ .name = "scrolling past the screen", .records = &.{
        o("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni\r\nj\r\nk\r\nl\r\nm"),
        o("\r\nn\r\no\r\n\x1b[41mp\x1b[0m"),
    } },

    // Inserting and deleting characters
    .{ .name = "ICH and DCH", .records = &.{
        o("abcdefghijklmnopqrst"),
        o("\x1b[1;3H\x1b[2@"),
        o("\x1b[1;8H\x1b[3P"),
        o("\x1b[2;1Hwide\xe4\xb8\xad\xe6\x96\x87end\x1b[2;3H\x1b[1P"),
    } },
    .{ .name = "insert mode", .records = &.{ o("abcdef\r"), o("\x1b[4hXY\x1b[4l") } },

    // Alternate screen
    .{ .name = "alt screen 1049", .records = &.{
        o("primary\r\nscreen"),
        o("\x1b[?1049h"),
        o("\x1b[44malt\x1b[0m"),
        o("\x1b[?1049l"),
    } },
    .{ .name = "alt screen 47 and 1047", .records = &.{
        o("primary"),
        o("\x1b[?47hforty-seven"),
        o("\x1b[?47l\x1b[?1047hten-forty-seven"),
        o("\x1b[?1047l"),
    } },
    .{ .name = "cursor save across alt screen", .records = &.{
        o("\x1b[3;5H\x1b7\x1b[?1049h\x1b[6;6Hx"),
        o("\x1b[?1049l\x1b8y"),
    } },

    // Wide and combining characters
    .{ .name = "wide characters", .records = &.{o("\xe4\xb8\xad\xe6\x96\x87 text \xf0\x9f\x98\x80")} },
    .{ .name = "wide character at the right margin", .records = &.{
        o("0123456789012345678"),
        o("\xe4\xb8\xad"),
        o("after"),
    } },
    .{ .name = "wide character without wraparound", .records = &.{
        o("\x1b[?7l0123456789012345678"),
        o("\xe4\xb8\xad"),
        o("\x1b[?7h"),
    } },
    .{ .name = "wide character overwritten", .records = &.{
        o("\xe4\xb8\xad\xe6\x96\x87"),
        o("\x1b[1;2Hx"),
        o("\x1b[1;3H\x1b[41my\x1b[0m"),
    } },
    .{ .name = "combining marks", .records = &.{o("e\xcc\x81 a\xcc\x88\xcc\xa3 n\xcc\x83")} },
    .{ .name = "combining marks without grapheme clustering", .records = &.{
        o("\x1b[?2027le\xcc\x81 a\xcc\x88\xcc\xa3 n\xcc\x83"),
    } },
    .{ .name = "combining mark at the right margin", .records = &.{
        o("0123456789012345678e"),
        o("\xcc\x81"),
        o("next"),
    } },
    .{ .name = "combining mark at the right margin without grapheme clustering", .records = &.{
        o("\x1b[?2027l0123456789012345678e"),
        o("\xcc\x81"),
        o("next"),
    } },
    .{ .name = "combining mark after moving back to an earlier row", .records = &.{
        o("\x1b[?2027le\r\nnext"),
        o("\x1b[1;2H\xcc\x81\x1b[2;5H"),
    } },
    .{ .name = "emoji with variation selector", .records = &.{o("\xe2\x9d\xa4\xef\xb8\x8f x \xe2\x9c\x94\xef\xb8\x8e y")} },
    .{ .name = "emoji with variation selector without grapheme clustering", .records = &.{
        o("\x1b[?2027l\xe2\x9d\xa4\xef\xb8\x8f x \xe2\x9c\x94\xef\xb8\x8e y"),
    } },
    .{ .name = "ZWJ sequence with grapheme clustering", .records = &.{
        o("\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 family"),
        o("\r\n\xf0\x9f\x87\xba\xf0\x9f\x87\xb8 flag"),
    } },
    .{ .name = "ZWJ sequence without grapheme clustering", .records = &.{
        o("\x1b[?2027l\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9 x"),
    } },
    .{
        .name = "cluster ending in ZWJ next to a pictograph",
        .records = &.{o("\x1b[1;3H\xe2\x9d\xa4\x1b[1;1H\xf0\x9f\x91\xa8\xe2\x80\x8d")},
        .known = "the host joins a cell to the cluster on its left when they would form one grapheme",
    },
    .{
        .name = "lone regional indicator next to a flag",
        .records = &.{o("\x1b[1;3H\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\x1b[1;1H\xf0\x9f\x87\xba")},
        .known = "the host joins a cell to the cluster on its left when they would form one grapheme",
    },
    .{
        .name = "row printed in both grapheme clustering modes",
        .records = &.{ o("\x1b[?2027l\xe2\x9d\xa4\xef\xb8\x8f"), o("\x1b[?2027h x") },
        .known = "the host lays out a whole row in one grapheme clustering mode",
    },

    // Wrapping
    .{ .name = "soft-wrapped lines", .records = &.{
        o("This line is long enough to wrap twice in twenty columns."),
        o("\r\nshort"),
    } },
    .{ .name = "pending wrap cursor", .records = &.{o("01234567890123456789")} },
    .{ .name = "reflow on resize", .records = &.{
        o("This line is long enough to wrap twice.\r\n\x1b[42mgreen\x1b[0m"),
        size(30, 6),
        o("x"),
        size(12, 10),
    } },
    .{ .name = "resize to the same size", .records = &.{ o("text \x1b[41mred\x1b[0m"), size(20, 8) } },
    .{ .name = "resize on the alt screen", .records = &.{
        o("\x1b[?1049h\x1b[44m\x1b[2Jblue"),
        size(25, 5),
        o("\x1b[5;25Hz"),
    } },

    // Colors and attributes
    .{ .name = "ANSI colors", .records = &.{
        o("\x1b[30ma\x1b[31mb\x1b[32mc\x1b[33md\x1b[34me\x1b[35mf\x1b[36mg\x1b[37mh"),
        o("\x1b[90ma\x1b[91mb\x1b[92mc\x1b[93md\x1b[94me\x1b[95mf\x1b[96mg\x1b[97mh\x1b[39m"),
        o("\r\n\x1b[40ma\x1b[41mb\x1b[42mc\x1b[43md\x1b[100me\x1b[107mf\x1b[49m"),
    } },
    .{ .name = "256 and RGB colors", .records = &.{
        o("\x1b[38;5;16ma\x1b[38;5;231mb\x1b[38;5;196mc\x1b[48;5;21md\x1b[48;5;244me\x1b[0m"),
        o("\r\n\x1b[38;2;255;128;0ma\x1b[48;2;0;64;128mb\x1b[38:2::1:2:3mc\x1b[48:5:99md\x1b[0m"),
        o("\r\n\x1b[38;5;3mpalette\x1b[38;2;205;205;0m rgb\x1b[0m"),
    } },
    .{ .name = "attributes", .records = &.{
        o("\x1b[1mb\x1b[2mf\x1b[22m\x1b[3mi\x1b[23m\x1b[5mk\x1b[25m\x1b[7mr\x1b[27m"),
        o("\x1b[8mh\x1b[28m\x1b[9ms\x1b[29m\x1b[53mo\x1b[55m\x1b[1;2;3mall\x1b[0m"),
    } },
    .{ .name = "underline styles and colors", .records = &.{
        o("\x1b[4ma\x1b[4:2mb\x1b[4:3mc\x1b[4:4md\x1b[4:5me\x1b[21mf\x1b[24m"),
        o("\r\n\x1b[4;58;5;196ma\x1b[58:2::0:255:0mb\x1b[58;2;0;0;255mc\x1b[59md\x1b[0m"),
        o("\r\n\x1b[4:3;58;5;2;41m  \x1b[0m"),
    } },
    .{ .name = "styled blank cells", .records = &.{o("\x1b[7m   \x1b[0m \x1b[4m   \x1b[9;41m \x1b[0m")} },

    // Cursor
    .{ .name = "cursor shapes", .records = &.{
        o("\x1b[5 q"),
        o("\x1b[6 q"),
        o("\x1b[3 q"),
        o("\x1b[4 q"),
        o("\x1b[1 q"),
        o("\x1b[0 q"),
        o("\x1b[?12h"),
        o("\x1b[?12l"),
    } },
    .{ .name = "cursor visibility", .records = &.{ o("\x1b[?25l"), o("\x1b[3;3H"), o("\x1b[?25h") } },
    .{ .name = "cursor movement", .records = &.{
        o("\x1b[5;10H"),
        o("\x1b[2A\x1b[3D"),
        o("\x1b[10G\x1b[2d"),
        o("\x1b[99;99H"),
        o("\x1bE\x1bD"),
    } },
    .{ .name = "origin mode", .records = &.{ o("\x1b[3;6r\x1b[?6h\x1b[1;1Hx\x1b[9;1Hy"), o("\x1b[?6l\x1b[r") } },
    .{ .name = "tabs", .records = &.{
        o("a\tb\tc"),
        o("\r\n\x1b[5G\x1bH\r\tx\x1b[g"),
        o("\r\n\x1b[3g\ty\x1b[Zz"),
    } },
    .{ .name = "repeat and DECALN", .records = &.{ o("ab\x1b[5b"), o("\x1b#8"), o("\x1b[3;3Hx") } },

    // Modes
    .{ .name = "mirrored input modes", .records = &.{
        o("\x1b[?1h"),
        o("\x1b[?1000h\x1b[?1006h"),
        o("\x1b[?1002h\x1b[?1003h\x1b[?1004h\x1b[?2004h"),
        o("\x1b[?1l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?2004l"),
    } },
    .{ .name = "other input modes", .records = &.{
        o("\x1b[?9h"),
        o("\x1b="),
        o("\x1b>\x1b[?66h\x1b[?67h"),
        o("\x1b[?1000h\x1b[?1005h"),
        o("\x1b[?1005l\x1b[?1015h"),
        o("\x1b[?1015l\x1b[?1016h"),
        o("\x1b[?1007l\x1b[?1036l\x1b[?1039h\x1b[?1035l"),
    } },
    .{ .name = "kitty keyboard flags", .records = &.{
        o("\x1b[>1u"),
        o("\x1b[>15u"),
        o("\x1b[=3;2u"),
        o("\x1b[<u"),
        o("\x1b[?1049h\x1b[>5u"),
        o("\x1b[?1049l"),
    } },
    .{ .name = "reverse video", .records = &.{ o("text \x1b[41mred\x1b[0m"), o("\x1b[?5h"), o("more") } },
    .{ .name = "synchronized output", .records = &.{
        o("before"),
        o("\x1b[?2026h\x1b[2J\x1b[Hduring"),
        o(" still"),
        o("\x1b[?2026l"),
    } },
    .{ .name = "reset", .records = &.{
        o("\x1b[?1h\x1b[?2004h\x1b[5 q\x1b[41mtext"),
        o("\x1bc"),
        o("after"),
    } },
    .{ .name = "title, bell, and hyperlink", .records = &.{
        o("\x1b]2;title\x07\x07"),
        o("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ text"),
    } },

    // Colors changed by the program
    .{
        .name = "OSC 4 palette change",
        .records = &.{ o("\x1b[31mred"), o("\x1b]4;1;rgb:12/34/56\x1b\\") },
        .known = "granite doesn't forward palette changes to the host",
    },
    .{
        .name = "OSC 10 and 11 default colors",
        .records = &.{ o("text"), o("\x1b]10;rgb:ff/00/00\x07\x1b]11;#000080\x07") },
        .known = "granite doesn't forward default color changes to the host",
    },
};
