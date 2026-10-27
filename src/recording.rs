//! The recording format written by granite-record and replayed by the
//! round-trip tests: a magic line, then records. An output record holds
//! one read() of the program's output. A size record holds the terminal
//! size from that point on; the first record is always a size record.
//!
//!   output: 'o', length (u32 little-endian), bytes
//!   size:   's', cols (u16 little-endian), rows (u16 little-endian)

use std::fmt;

pub const MAGIC: &[u8] = b"granite-recording 1\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Record<'a> {
    Output(&'a [u8]),
    Size(Size),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    NotARecording,
    Truncated,
    BadRecord,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Error::NotARecording => "not a recording",
            Error::Truncated => "truncated recording",
            Error::BadRecord => "bad record",
        })
    }
}

impl std::error::Error for Error {}

/// Append `record` to `out`.
pub fn write(out: &mut Vec<u8>, record: Record) {
    match record {
        Record::Output(data) => {
            out.push(b'o');
            out.extend_from_slice(&(data.len() as u32).to_le_bytes());
            out.extend_from_slice(data);
        }
        Record::Size(s) => {
            out.push(b's');
            out.extend_from_slice(&s.cols.to_le_bytes());
            out.extend_from_slice(&s.rows.to_le_bytes());
        }
    }
}

pub struct Reader<'a> {
    rest: &'a [u8],
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Result<Self, Error> {
        match data.strip_prefix(MAGIC) {
            Some(rest) => Ok(Reader { rest }),
            None => Err(Error::NotARecording),
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<Record<'a>>, Error> {
        let Some(&tag) = self.rest.first() else { return Ok(None) };
        if self.rest.len() < 5 {
            return Err(match tag {
                b'o' | b's' => Error::Truncated,
                _ => Error::BadRecord,
            });
        }
        match tag {
            b'o' => {
                let len = u32::from_le_bytes(self.rest[1..5].try_into().unwrap()) as usize;
                if self.rest.len() - 5 < len {
                    return Err(Error::Truncated);
                }
                let data = &self.rest[5..5 + len];
                self.rest = &self.rest[5 + len..];
                Ok(Some(Record::Output(data)))
            }
            b's' => {
                let size = Size {
                    cols: u16::from_le_bytes([self.rest[1], self.rest[2]]),
                    rows: u16::from_le_bytes([self.rest[3], self.rest[4]]),
                };
                self.rest = &self.rest[5..];
                Ok(Some(Record::Size(size)))
            }
            _ => Err(Error::BadRecord),
        }
    }
}
