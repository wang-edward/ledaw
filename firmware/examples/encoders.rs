#![no_std]
#![no_main]

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
    info!("Encoder GPIO test: results over RTT; MIDI UART disabled");
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

    // Encoder 1..4: A, B, push switch, as wired in mcu.kicad_sch.
    // A/B have external pull-ups; switches close to ground.
    let mut a = [
        pins.gpio35.into_floating_input().into_dyn_pin(),
        pins.gpio37.into_floating_input().into_dyn_pin(),
        pins.gpio6.into_floating_input().into_dyn_pin(),
        pins.gpio8.into_floating_input().into_dyn_pin(),
    ];
    let mut b = [
        pins.gpio36.into_floating_input().into_dyn_pin(),
        pins.gpio38.into_floating_input().into_dyn_pin(),
        pins.gpio7.into_floating_input().into_dyn_pin(),
        pins.gpio9.into_floating_input().into_dyn_pin(),
    ];
    let mut switches = [
        pins.gpio33.into_pull_up_input().into_dyn_pin(),
        pins.gpio34.into_pull_up_input().into_dyn_pin(),
        pins.gpio11.into_pull_up_input().into_dyn_pin(),
        pins.gpio12.into_pull_up_input().into_dyn_pin(),
    ];
    let mut states = [0u8; 4];
    for i in 0..4 {
        states[i] = (u8::from(a[i].is_high().unwrap()) << 1) | u8::from(b[i].is_high().unwrap());
    }
    let mut counts = [0i32; 4];
    let mut invalid = [0u32; 4];
    let mut pressed = [false; 4];
    let mut debounce = [0u8; 4];
    let mut changed = [true; 4];
    let mut ticks = 0u16;

    loop {
        for i in 0..4 {
            let next = (u8::from(a[i].is_high().unwrap()) << 1) | u8::from(b[i].is_high().unwrap());
            if next != states[i] {
                if next ^ states[i] == 3 {
                    invalid[i] = invalid[i].saturating_add(1);
                } else {
                    counts[i] = counts[i].saturating_add(quadrature_delta(states[i], next));
                }
                states[i] = next;
                changed[i] = true;
            }
            let down = switches[i].is_low().unwrap();
            if down == pressed[i] {
                debounce[i] = 0;
            } else {
                debounce[i] += 1;
                if debounce[i] == 80 {
                    pressed[i] = down;
                    debounce[i] = 0;
                    changed[i] = true;
                }
            }
        }

        // Poll at roughly 4 kHz; limit logging to avoid slowing the sampling loop.
        // Counts are quadrature transitions, NOT calibrated detents.
        if ticks == 0 {
            for i in 0..4 {
                if changed[i] {
                    info!(
                        "ENC{} A={} B={} transitions={} invalid={} pressed={}",
                        i + 1,
                        states[i] >> 1,
                        states[i] & 1,
                        counts[i],
                        invalid[i],
                        pressed[i]
                    );
                    changed[i] = false;
                }
            }
        }
        ticks = (ticks + 1) % 400;
        delay.delay_us(250);
    }
}

// Positive sequence: 00 -> 01 -> 11 -> 10 -> 00. Physical CW depends on wiring.
fn quadrature_delta(previous: u8, next: u8) -> i32 {
    const DELTA: [i32; 16] = [0, 1, -1, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, -1, 1, 0];
    DELTA[usize::from((previous << 2) | next)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn movement(states: &[u8]) -> i32 {
        states
            .windows(2)
            .map(|s| quadrature_delta(s[0], s[1]))
            .sum()
    }

    #[test]
    fn directions_and_contact_bounce() {
        assert_eq!(movement(&[0, 1, 3, 2, 0]), 4);
        assert_eq!(movement(&[0, 2, 3, 1, 0]), -4);
        assert_eq!(movement(&[0, 1, 0, 1, 3, 2, 0]), 4);
    }

    #[test]
    fn stationary_and_skipped_states_do_not_count() {
        for state in 0..4 {
            assert_eq!(quadrature_delta(state, state), 0);
            assert_eq!(quadrature_delta(state, state ^ 3), 0);
        }
    }
}
