#![no_std]
#![no_main]

use defmt::info;
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
    info!("UART echo test: waiting for ping");
    let mut pac = pac::Peripherals::take().unwrap();
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

    let pins = hal::gpio::Pins::new(
        pac.IO_BANK0,
        pac.PADS_BANK0,
        sio.gpio_bank0,
        &mut pac.RESETS,
    );

    let uart_pins = (pins.gpio0.into_function(), pins.gpio1.into_function());
    let uart = UartPeripheral::new(pac.UART0, uart_pins, &mut pac.RESETS)
        .enable(
            UartConfig::new(115_200u32.Hz(), DataBits::Eight, None, StopBits::One),
            clocks.peripheral_clock.freq(),
        )
        .unwrap();

    let ping = b"ping\n";
    let mut ping_index = 0;

    loop {
        // Preserve partial commands between reads.
        let mut received = [0u8; 32];
        if let Ok(count) = uart.read_raw(&mut received) {
            for &byte in &received[..count] {
                if byte == ping[ping_index] {
                    ping_index += 1;
                    if ping_index == ping.len() {
                        uart.write_full_blocking(b"pong\r\n");
                        ping_index = 0;
                    }
                } else {
                    ping_index = usize::from(byte == ping[0]);
                }
            }
        }
    }
}
