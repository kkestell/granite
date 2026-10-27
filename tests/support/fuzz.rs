//! Seed-compatible port of Zig's Xoshiro256++ fuzzer, including integer widths.
use super::Input;
use granite::recording::Size;

pub struct Random {
    s: [u64; 4],
}
impl Random {
    pub fn new(mut seed: u64) -> Self {
        let s = std::array::from_fn(|_| {
            seed = seed.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = seed;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            z ^ (z >> 31)
        });
        Self { s }
    }
    pub fn next(&mut self) -> u64 {
        let s = &mut self.s;
        let r = s[0].wrapping_add(s[3]).rotate_left(23).wrapping_add(s[0]);
        let t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = s[3].rotate_left(45);
        r
    }
    pub fn boolean(&mut self) -> bool {
        self.next() & 1 != 0
    }
    pub fn byte(&mut self) -> u8 {
        self.next() as u8
    }
    pub fn less(&mut self, bits: u32, n: u64) -> u64 {
        let mask = u64::MAX >> (64 - bits);
        let threshold = (n.wrapping_neg() & mask) % n;
        loop {
            let m = u128::from(self.next() & mask) * u128::from(n);
            if (m as u64 & mask) >= threshold {
                return (m >> bits) as u64;
            }
        }
    }
    pub fn range(&mut self, bits: u32, low: u64, high: u64) -> u64 {
        low + self.less(bits, high - low + 1)
    }
    fn pick<'a, T>(&mut self, values: &'a [T]) -> &'a T {
        &values[self.less(64, values.len() as u64) as usize]
    }
}
const TEXTS: &[&[u8]] = &[
    b"a",
    b"hello",
    b"The quick brown fox",
    b" ",
    b"    ",
    b"\xe4\xb8\xad",
    b"\xe6\x96\x87\xe5\xad\x97",
    b"\xf0\x9f\x98\x80",
    b"\xe2\x9d\xa4\xef\xb8\x8f",
    b"e\xcc\x81",
    b"a\xcc\x88\xcc\xa3",
    b"\xcc\x81",
    b"\xe2\x94\x80\xe2\x94\x82\xe2\x94\x8c",
    b"\xef\xbd\x81",
    b"\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d",
];
const MODES: &[u16] = &[
    1, 4, 6, 7, 9, 12, 25, 47, 66, 67, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1035,
    1036, 1039, 1047, 1048, 1049, 2004, 2026,
];
pub fn generate(r: &mut Random) -> Vec<Input> {
    let mut records = vec![Input::Output(
        if r.boolean() {
            b"\x1b[?2027h"
        } else {
            b"\x1b[?2027l"
        }
        .to_vec(),
    )];
    let chunks = r.range(64, 1, 40);
    for _ in 0..chunks {
        if r.less(8, 30) == 0 {
            records.push(Input::Size(Size {
                cols: r.range(16, 4, 60) as u16,
                rows: r.range(16, 2, 20) as u16,
            }));
            continue;
        }
        let mut out = Vec::new();
        let tokens = r.range(64, 1, 24);
        for _ in 0..tokens {
            token(&mut out, r);
        }
        records.push(Input::Output(out));
    }
    records
}
fn token(out: &mut Vec<u8>, r: &mut Random) {
    let text = match r.less(8, 24) {
        0..=5 => {
            out.extend_from_slice(r.pick(TEXTS));
            return;
        }
        6 => {
            let n = r.range(64, 1, 80);
            for _ in 0..n {
                out.push(r.range(8, 0x20, 0x7e) as u8);
            }
            return;
        }
        7 => ["\r\n", "\n", "\r", "\x08", "\t", "\x07"][r.less(8, 6) as usize].to_owned(),
        8 => format!("\x1b[{};{}H", r.range(8, 0, 30), r.range(8, 0, 70)),
        9 => format!(
            "\x1b[{}{}",
            r.range(8, 0, 12),
            b"ABCDEFGd`"[r.less(64, 9) as usize] as char
        ),
        10 => format!(
            "\x1b[{}{}",
            r.range(8, 0, 3),
            b"JK"[r.less(64, 2) as usize] as char
        ),
        11 => format!(
            "\x1b[{}{}",
            r.range(8, 0, 8),
            b"@PXLMSTb"[r.less(64, 8) as usize] as char
        ),
        12 => {
            if r.boolean() {
                "\x1b[r".to_owned()
            } else {
                format!("\x1b[{};{}r", r.range(8, 1, 10), r.range(8, 2, 24))
            }
        }
        13..=15 => {
            sgr(out, r);
            return;
        }
        16 | 17 => format!(
            "\x1b[?{}{}",
            r.pick(MODES),
            b"hl"[r.less(64, 2) as usize] as char
        ),
        18 => format!("\x1b[{} q", r.range(8, 0, 6)),
        19 => [
            "\x1b7", "\x1b8", "\x1bM", "\x1bD", "\x1bE", "\x1bH", "\x1b=", "\x1b>",
        ][r.less(8, 8) as usize]
            .to_owned(),
        20 => match r.less(8, 4) {
            0 => format!("\x1b[>{}u", r.range(8, 0, 31)),
            1 => format!("\x1b[<{}u", r.range(8, 0, 3)),
            2 => format!("\x1b[={};{}u", r.range(8, 0, 31), r.range(8, 1, 3)),
            _ => format!("\x1b[{}g", if r.boolean() { 0 } else { 3 }),
        },
        21 => format!(
            "\x1b]{};title {}\x07",
            if r.boolean() { 0 } else { 2 },
            r.byte()
        ),
        22 => if r.less(8, 8) == 0 {
            "\x1bc"
        } else {
            "\x1b[4h\x1b[4l"
        }
        .to_owned(),
        _ => if r.boolean() { "\x1b#8" } else { "\x1b[!p" }.to_owned(),
    };
    out.extend_from_slice(text.as_bytes());
}
fn sgr(out: &mut Vec<u8>, r: &mut Random) {
    let mut text = String::from("\x1b[");
    let n = r.range(64, 1, 4);
    for i in 0..n {
        if i > 0 {
            text.push(';');
        }
        let part = match r.less(8, 12) {
            0 => "0".to_owned(),
            1 => r.range(8, 1, 9).to_string(),
            2 => r.range(8, 21, 29).to_string(),
            3 => r.range(8, 30, 49).to_string(),
            4 => r.range(8, 90, 107).to_string(),
            5 => format!("{}8:5:{}", b"345"[r.less(64, 3) as usize] as char, r.byte()),
            6 => format!("{}8;5;{}", b"345"[r.less(64, 3) as usize] as char, r.byte()),
            7 => format!(
                "{}8;2;{};{};{}",
                b"345"[r.less(64, 3) as usize] as char,
                r.byte(),
                r.byte(),
                r.byte()
            ),
            8 => format!("4:{}", r.range(8, 0, 5)),
            9 => if r.boolean() { "53" } else { "55" }.to_owned(),
            10 => if r.boolean() { "39;49" } else { "59" }.to_owned(),
            _ => format!("58:2::{}:{}:{}", r.byte(), r.byte(), r.byte()),
        };
        text.push_str(&part);
    }
    text.push('m');
    out.extend_from_slice(text.as_bytes());
}
// Reference FNV-1a hashes produced by Zig's original fuzz.generate, over
// recording records including the initial size. Lock down draw order and widths,
// not just the underlying PRNG, so seeds reproduce the same stream after the port.
#[test]
fn zig_fuzz_streams() {
    use granite::recording::{self, Record};
    for (seed, want) in [
        (1, 0xbdaba7d1cd367833),
        (42, 0x1f3eff24296414e3),
        (300, 0xcdb71588539ba946),
        (u64::MAX, 0x5ba194158c97f8c5),
    ] {
        let mut r = Random::new(seed);
        let initial = Size {
            cols: r.range(16, 4, 60) as u16,
            rows: r.range(16, 2, 20) as u16,
        };
        let mut bytes = Vec::new();
        recording::write(&mut bytes, Record::Size(initial));
        for record in generate(&mut r) {
            recording::write(
                &mut bytes,
                match &record {
                    Input::Size(s) => Record::Size(*s),
                    Input::Output(b) => Record::Output(b),
                },
            );
        }
        let hash = bytes.iter().fold(14695981039346656037_u64, |h, &b| {
            (h ^ u64::from(b)).wrapping_mul(1099511628211)
        });
        assert_eq!(hash, want, "Zig fuzz stream for seed {seed}");
    }
}
#[test]
fn zig_prng_sequence() {
    let mut r = Random::new(0);
    for want in [
        0x53175d61490b23df,
        0x61da6f3dc380d507,
        0x5c0fdf91ec9a7bfc,
        0x02eebf8c3bbe5e1a,
        0x7eca04ebaf4a5eea,
        0x0543c37757f08d9a,
    ] {
        assert_eq!(r.next(), want);
    }
}
