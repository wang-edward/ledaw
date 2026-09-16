#![no_std]
#![no_main]

use defmt::info;
use defmt_rtt as _;
use embedded_hal::digital::InputPin;
use panic_probe as _;
use rp235x_hal::clocks::init_clocks_and_plls;
use rp235x_hal::{self as hal, entry};
use rp235x_hal::{Clock, pac};

#[path = "support/joystick_display.rs"]
mod joystick_display;

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
                    let frame = joystick_display::render(x, y, pressed);
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
