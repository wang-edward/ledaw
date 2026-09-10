#![no_std]
#![no_main]

use defmt::*;
use defmt_rtt as _;
use embedded_hal::digital::{InputPin, OutputPin};
use hal::uart::{DataBits, StopBits, UartConfig, UartPeripheral};
use panic_probe as _;
use rp235x_hal::clocks::init_clocks_and_plls;
use rp235x_hal::fugit::RateExtU32;
use rp235x_hal::{self as hal, entry};
use rp235x_hal::{Clock, pac};

// Provide an alias for our BSP so we can switch targets quickly.
// Uncomment the BSP you included in Cargo.toml, the rest of the code does not need to change.
// use some_bsp;

/// Tell the Boot ROM about our application
#[unsafe(link_section = ".start_block")]
#[used]
pub static IMAGE_DEF: hal::block::ImageDef = hal::block::ImageDef::secure_exe();

#[entry]
fn main() -> ! {
    info!("Program start");
    let mut pac = pac::Peripherals::take().unwrap();
    let core = cortex_m::Peripherals::take().unwrap();
    let mut watchdog = hal::Watchdog::new(pac.WATCHDOG);
    let sio = hal::Sio::new(pac.SIO);

    // External high-speed crystal on the pico board is 12Mhz
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

    let uart_pins = (pins.gpio0.into_function(), pins.gpio1.into_function());
    let _uart = UartPeripheral::new(pac.UART0, uart_pins, &mut pac.RESETS)
        .enable(
            UartConfig::new(115_200u32.Hz(), DataBits::Eight, None, StopBits::One),
            clocks.peripheral_clock.freq(),
        )
        .unwrap();

    // Switches connect a row to each diode's anode; its cathode connects to the column.
    // Rows are active high and idle rows are low so only the selected row can raise a column.
    let mut rows = [
        pins.gpio16.into_push_pull_output().into_dyn_pin(),
        pins.gpio17.into_push_pull_output().into_dyn_pin(),
        pins.gpio18.into_push_pull_output().into_dyn_pin(),
    ];
    for row in &mut rows {
        row.set_low().unwrap();
    }

    // Columns are listed in physical column order, GPIO32 through GPIO19.
    let mut columns = [
        pins.gpio32.into_pull_down_input().into_dyn_pin(),
        pins.gpio31.into_pull_down_input().into_dyn_pin(),
        pins.gpio30.into_pull_down_input().into_dyn_pin(),
        pins.gpio29.into_pull_down_input().into_dyn_pin(),
        pins.gpio28.into_pull_down_input().into_dyn_pin(),
        pins.gpio27.into_pull_down_input().into_dyn_pin(),
        pins.gpio26.into_pull_down_input().into_dyn_pin(),
        pins.gpio25.into_pull_down_input().into_dyn_pin(),
        pins.gpio24.into_pull_down_input().into_dyn_pin(),
        pins.gpio23.into_pull_down_input().into_dyn_pin(),
        pins.gpio22.into_pull_down_input().into_dyn_pin(),
        pins.gpio21.into_pull_down_input().into_dyn_pin(),
        pins.gpio20.into_pull_down_input().into_dyn_pin(),
        pins.gpio19.into_pull_down_input().into_dyn_pin(),
    ];
    let mut previous = [u16::MAX; 3];

    loop {
        let mut scan = [0u16; 3];

        for (row_index, row) in rows.iter_mut().enumerate() {
            row.set_high().unwrap();
            delay.delay_us(5);

            for (column_index, column) in columns.iter_mut().enumerate() {
                if column.is_high().unwrap() {
                    scan[row_index] |= 1 << column_index;
                }
            }

            row.set_low().unwrap();
        }

        if scan != previous {
            // Each bit is a pressed key; bit 0 is GPIO32 and bit 13 is GPIO19.
            info!(
                "matrix: {=u16:04x} {=u16:04x} {=u16:04x}",
                scan[0], scan[1], scan[2]
            );
            previous = scan;
        }

        delay.delay_ms(1);
    }
}

/// Program metadata for `picotool info`
#[unsafe(link_section = ".bi_entries")]
#[used]
pub static PICOTOOL_ENTRIES: [rp235x_hal::binary_info::EntryAddr; 5] = [
    rp235x_hal::binary_info::rp_cargo_bin_name!(),
    rp235x_hal::binary_info::rp_cargo_version!(),
    rp235x_hal::binary_info::rp_program_description!(c"RP2350 Template"),
    rp235x_hal::binary_info::rp_cargo_homepage_url!(),
    rp235x_hal::binary_info::rp_program_build_attribute!(),
];

// End of file
