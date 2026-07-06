#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_time::{Duration, Timer};

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let _p = embassy_rp::init(Default::default());
    loop {
        defmt::info!("hello");
        Timer::after(Duration::from_secs(1)).await;
    }
}
