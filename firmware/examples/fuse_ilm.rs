//! Read the eFuse ILM voltage over RTT: cargo embed --example fuse_ilm
#![no_std]
#![no_main]

use defmt_rtt as _;
use panic_probe as _;
use rp235x_hal::{self as hal, Clock, entry, pac};

#[unsafe(link_section = ".start_block")]
#[used]
pub static IMAGE_DEF: hal::block::ImageDef = hal::block::ImageDef::secure_exe();

// Nominal ADC reference. Adjust to the measured ADC supply for accurate voltage.
const ADC_VREF_MV: u32 = 3300;
const SAMPLES: u32 = 32;

#[entry]
fn main() -> ! {
    let mut pac = pac::Peripherals::take().unwrap();
    let core = cortex_m::Peripherals::take().unwrap();
    let mut watchdog = hal::Watchdog::new(pac.WATCHDOG);
    let clocks = hal::clocks::init_clocks_and_plls(
        12_000_000,
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

    // mcu.kicad_sch: U301 pin 52, GPIO41/ADC1 -> FUSE_ILM.
    // usb.kicad_sch: TPS259531 ILM, with a 681-ohm resistor to ground.
    // HAL 0.3's AdcPin only accepts GPIO26..29, so configure this B-package
    // analog pin through the PAC. Do not load the current-limit node with pulls.
    pac.RESETS
        .reset()
        .modify(|_, w| w.io_bank0().set_bit().pads_bank0().set_bit());
    pac.RESETS
        .reset()
        .modify(|_, w| w.io_bank0().clear_bit().pads_bank0().clear_bit());
    while {
        let done = pac.RESETS.reset_done().read();
        done.io_bank0().bit_is_clear() || done.pads_bank0().bit_is_clear()
    } {}
    pac.IO_BANK0
        .gpio(41)
        .gpio_ctrl()
        .write(|w| unsafe { w.funcsel().bits(31) });
    pac.PADS_BANK0.gpio(41).modify(|_, w| {
        w.ie()
            .clear_bit()
            .od()
            .set_bit()
            .pue()
            .clear_bit()
            .pde()
            .clear_bit()
            .iso()
            .clear_bit()
    });

    let adc = hal::Adc::new(pac.ADC, &mut pac.RESETS).free();
    adc.cs().modify(|_, w| unsafe { w.ainsel().bits(1) });
    defmt::info!(
        "FUSE_ILM: GPIO41 / ADC1, nominal reference={} mV",
        ADC_VREF_MV
    );

    loop {
        let mut sum = 0u32;
        let mut failed = false;
        for _ in 0..SAMPLES {
            adc.cs().modify(|_, w| w.start_once().set_bit());
            while adc.cs().read().ready().bit_is_clear() {}
            failed |= adc.cs().read().err().bit_is_set();
            sum += u32::from(adc.result().read().result().bits());
            delay.delay_ms(1);
        }
        if failed {
            defmt::warn!("FUSE_ILM: ADC conversion error");
        } else {
            let raw = (sum + SAMPLES / 2) / SAMPLES;
            let mv = (sum * ADC_VREF_MV + SAMPLES * 4096 / 2) / (SAMPLES * 4096);
            defmt::info!("FUSE_ILM: raw={} / 4095, voltage={} mV", raw, mv);
        }
        delay.delay_ms(468);
    }
}
