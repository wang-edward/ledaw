#![no_std]
#![no_main]

use defmt::{info, warn};
use defmt_rtt as _;
use hal::uart::{DataBits, StopBits, UartConfig, UartPeripheral};
use panic_probe as _;
use rp235x_hal::clocks::init_clocks_and_plls;
use rp235x_hal::fugit::RateExtU32;
use rp235x_hal::{self as hal, entry};
use rp235x_hal::{Clock, pac};

/// Tell the Boot ROM about our application
#[unsafe(link_section = ".start_block")]
#[used]
pub static IMAGE_DEF: hal::block::ImageDef = hal::block::ImageDef::secure_exe();

#[entry]
fn main() -> ! {
    info!("MIDI loopback: connect MIDI OUT to MIDI IN; results appear here over RTT");
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

    // mcu.kicad_sch: GPIO4 -> MIDI output driver, GPIO5 <- input optocoupler.
    let uart_pins = (pins.gpio4.into_function(), pins.gpio5.into_function());
    let uart = UartPeripheral::new(pac.UART1, uart_pins, &mut pac.RESETS)
        .enable(
            UartConfig::new(31_250u32.Hz(), DataBits::Eight, None, StopBits::One),
            clocks.peripheral_clock.freq(),
        )
        .unwrap();

    let mut note = 0u8;
    let mut passed = 0u32;
    let mut failed = 0u32;

    loop {
        // Discard old input before each attempt. Six bytes fit in the RX FIFO,
        // so receiving can begin after the blocking transmit without losing data.
        let mut buffer = [0u8; 32];
        let _ = uart.read_raw(&mut buffer);
        // Channel 1 note-on followed by note-off. Vary data each round to test
        // different bit patterns and avoid accepting the previous round's reply.
        let expected = [0x90, note, 0x7f, 0x80, note, 0x00];
        uart.write_full_blocking(&expected);

        let mut received = 0usize;
        let mut matches = true;
        let mut read_error = false;
        // Observe the whole 100 ms window, including unexpected extra bytes.
        for _ in 0..100 {
            if uart.uart_is_readable() {
                match uart.read_raw(&mut buffer) {
                    Ok(count) => {
                        for byte in &buffer[..count] {
                            if expected.get(received) != Some(byte) {
                                matches = false;
                            }
                            received += 1;
                        }
                    }
                    Err(_) => read_error = true,
                }
            }
            delay.delay_ms(1);
        }

        if received == expected.len() && matches && !read_error {
            passed = passed.saturating_add(1);
            info!(
                "MIDI PASS: note={} bytes={} passed={} failed={}",
                note, received, passed, failed
            );
        } else {
            failed = failed.saturating_add(1);
            warn!(
                "MIDI FAIL: note={} received={}/6 mismatch={} uart_error={} passed={} failed={}",
                note, received, !matches, read_error, passed, failed
            );
        }

        note = (note + 1) & 0x7f;
        delay.delay_ms(900);
    }
}
