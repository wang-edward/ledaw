## Prerequisites
Install the embedded Rust target:
```sh
rustup target add thumbv8m.main-none-eabihf
```

Install [cargo-embed](https://probe.rs/docs/tools/cargo-embed/):
```sh
cargo install cargo-embed
```

Load the Raspberry Pi Debug Probe firmware onto the RP2040.
```sh
cp probe/debugprobe_on_pico.uf2 /media/$USER/RPI-RP2/
```

Connect the RP2040 to the computer over USB and connect its SWD pins to the RP2350:
```text
RP2040 GP2 -> RP2350 SWCLK
RP2040 GP3 -> RP2350 SWDIO
RP2040 GND -> carrier GND
```


## Build
Run this from the `firmware` directory so Cargo loads its embedded target and runner configuration:
```sh
cargo build
```

Flash And Run Over SWD
```sh
cargo embed
```

Check Probe Connection
```sh
probe-rs list
probe-rs info --chip RP235x
```
