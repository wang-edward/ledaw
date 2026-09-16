use core::fmt::{self, Write};

pub struct Frame {
    bytes: [u8; 1024],
    len: usize,
}

impl Frame {
    pub fn as_str(&self) -> &str {
        core::str::from_utf8(&self.bytes[..self.len]).unwrap()
    }
}

impl Write for Frame {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        let end = self.len + text.len();
        if end > self.bytes.len() {
            return Err(fmt::Error);
        }
        self.bytes[self.len..end].copy_from_slice(text.as_bytes());
        self.len = end;
        Ok(())
    }
}

pub fn render(x: u16, y: u16, pressed: bool) -> Frame {
    // Rotate the plot 90 degrees clockwise: raw +Y goes right, raw +X goes down.
    // Full ADC range, rounded to the nearest cell; header values stay unrotated.
    let column = (u32::from(y.min(4095)) * 20 + 2047) / 4095;
    let row = (u32::from(x.min(4095)) * 10 + 2047) / 4095;
    let mut frame = Frame {
        bytes: [0; 1024],
        len: 0,
    };
    write!(frame, "\x1b[HJoystick / RTT    Ctrl+C to stop\x1b[K\n").unwrap();
    writeln!(
        frame,
        "X={:4}  Y={:4}  button={}\x1b[K",
        x,
        y,
        if pressed { "PRESSED" } else { "released" }
    )
    .unwrap();
    frame.write_str("          X=0\x1b[K\n").unwrap();
    frame
        .write_str("  +---------------------+\x1b[K\n")
        .unwrap();
    for r in 0..11 {
        frame.write_str("  |").unwrap();
        for c in 0..21 {
            let cell = if r == row && c == column {
                if pressed { "@" } else { "O" }
            } else if r == 5 && c == 10 {
                "+"
            } else if r == 5 {
                "-"
            } else if c == 10 {
                "|"
            } else {
                " "
            };
            frame.write_str(cell).unwrap();
        }
        frame.write_str("|\x1b[K\n").unwrap();
    }
    frame
        .write_str("  +---------------------+\x1b[K\n")
        .unwrap();
    frame
        .write_str("Y=0       X=4095    Y=4095\x1b[K\n")
        .unwrap();
    frame
        .write_str("O = position   @ = pressed\x1b[K\n\x1b[J")
        .unwrap();
    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check_marker(x: u16, y: u16, pressed: bool, row: usize, column: usize) {
        let frame = render(x, y, pressed);
        let rows: [_; 11] = core::array::from_fn(|i| frame.as_str().lines().nth(i + 4).unwrap());
        let marker = if pressed { b'@' } else { b'O' };
        assert_eq!(rows[row].as_bytes()[column + 3], marker);
        assert_eq!(
            rows.iter()
                .flat_map(|r| r.bytes())
                .filter(|b| *b == marker)
                .count(),
            1
        );
        assert!(frame.as_str().starts_with("\x1b[H"));
        assert!(frame.as_str().ends_with("\x1b[J"));
    }

    #[test]
    fn center_corners_and_pressed_marker() {
        check_marker(2048, 2048, false, 5, 10);
        check_marker(0, 0, false, 0, 0);
        check_marker(4095, 0, false, 10, 0);
        check_marker(0, 4095, false, 0, 20);
        check_marker(4095, 4095, true, 10, 20);
        check_marker(u16::MAX, u16::MAX, true, 10, 20);
    }
}
