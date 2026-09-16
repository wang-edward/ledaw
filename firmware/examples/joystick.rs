#![no_std]
#![no_main]

use core::fmt::{self, Write};
use defmt::info;
use defmt_rtt as _;
use embedded_hal::digital::InputPin;
use panic_probe as _;
use rp235x_hal::clocks::init_clocks_and_plls;
use rp235x_hal::{self as hal, entry};
use rp235x_hal::{Clock, pac};

/// Tell the Boot ROM about our application
#[unsafe(link_section = ".start_block")]
#[used]
pub static IMAGE_DEF: hal::block::ImageDef = hal::block::ImageDef::secure_exe();

#[entry]
fn main() -> ! {
    // Use `cargo joystick` for a terminal that interprets ANSI cursor controls.
    info!("\x1b[2J\x1b[HStarting joystick display...");
    let mut pac = pac::Peripherals::take().unwrap();
    let core = cortex_m::Peripherals::take().unwrap();
    let mut watchdog = hal::Watchdog::new(pac.WATCHDOG);
    let sio = hal::Sio::new(pac.SIO);

    // The board uses a 12 MHz crystal.
    let external_xtal_freq_hz = 12_000_000u32;
    let clocks = init_clocks_and_plls(
        external_xtal_freq_hz,
        pac.XOSC,
        pac.CLOCKS,
        pac.PLL_SYS,
        pac.PLL_USB,
        &mut pac.RESETS,
        &mut watchdog,
    )
    .ok()
    .unwrap();

    let mut delay = cortex_m::delay::Delay::new(core.SYST, clocks.system_clock.freq().to_Hz());

    let pins = hal::gpio::Pins::new(
        pac.IO_BANK0,
        pac.PADS_BANK0,
        sio.gpio_bank0,
        &mut pac.RESETS,
    );

    // Never select a UART function or drive either MIDI pin in these tests.
    let _midi_tx = pins.gpio4.into_floating_input();
    let _midi_rx = pins.gpio5.into_floating_input();

    // RP2354's 80-pin package: GPIO47 = ADC7 (X), GPIO46 = ADC6 (Y).
    // rp235x-hal 0.3 AdcPin only accepts GPIO26..29, so configure these pads
    // explicitly and use the PAC for single conversions on channels 7 and 6.
    let mut x_pin = pins.gpio47.into_floating_input();
    let mut y_pin = pins.gpio46.into_floating_input();
    x_pin.set_input_enable(false);
    y_pin.set_input_enable(false);
    x_pin.set_output_enable_override(hal::gpio::OutputEnableOverride::Disable);
    y_pin.set_output_enable_override(hal::gpio::OutputEnableOverride::Disable);
    let adc = hal::Adc::new(pac.ADC, &mut pac.RESETS).free();
    let mut switch = pins.gpio10.into_pull_up_input();
    let mut pressed = false;
    let mut debounce = 0u8;
    let mut ticks = 0u8;

    loop {
        let down = switch.is_low().unwrap();
        if down == pressed {
            debounce = 0;
        } else {
            debounce += 1;
            if debounce == 20 {
                pressed = down;
                debounce = 0;
            }
        }
        if ticks == 0 {
            match (read_axis(&adc, 7), read_axis(&adc, 6)) {
                (Some(x), Some(y)) => {
                    let frame = render(x, y, pressed);
                    info!("{=str}", frame.as_str());
                }
                _ => {
                    info!("\x1b[HJOYSTICK ADC conversion error; no current position\x1b[K\n\x1b[J")
                }
            }
        }
        ticks = (ticks + 1) % 100;
        delay.delay_ms(1);
    }
}

fn read_axis(adc: &pac::ADC, channel: u8) -> Option<u16> {
    while adc.cs().read().ready().bit_is_clear() {}
    // Only called with valid ADC channels 6 and 7 for the 80-pin chip.
    adc.cs()
        .modify(|_, w| unsafe { w.ainsel().bits(channel).start_once().set_bit() });
    while adc.cs().read().ready().bit_is_clear() {}
    if adc.cs().read().err().bit_is_set() {
        None
    } else {
        Some(adc.result().read().result().bits())
    }
}

struct Frame {
    bytes: [u8; 1024],
    len: usize,
}

impl Frame {
    fn as_str(&self) -> &str {
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

fn render(x: u16, y: u16, pressed: bool) -> Frame {
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
