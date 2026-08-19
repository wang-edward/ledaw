//! Desktop audio output via cpal. Replaces the libsoundio callback from `main.zig`.
//! The engine renders mono; we fan it out to every output channel (matching the Zig
//! behavior of copying the mono block to all channels).
//!
//! NOTE (real-time): this locks the shared `Mutex<Engine>` inside the audio callback.

use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::engine::Engine;

pub struct AudioOut {
    _stream: cpal::Stream,
    pub sample_rate: f32,
}

/// The default output device's sample rate — create the `Engine` with this.
pub fn default_output_sample_rate() -> Result<f32, Box<dyn std::error::Error>> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("no default output device")?;
    Ok(device.default_output_config()?.sample_rate().0 as f32)
}

/// Start streaming `engine` to the default output device.
pub fn start(engine: Arc<Mutex<Engine>>) -> Result<AudioOut, Box<dyn std::error::Error>> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("no default output device")?;
    let supported = device.default_output_config()?;
    let sample_rate = supported.sample_rate().0 as f32;
    let channels = supported.channels() as usize;
    let config: cpal::StreamConfig = supported.into();

    let err_fn = |e| eprintln!("audio stream error: {e}");
    let mut mono: Vec<f32> = Vec::new(); // reused across callbacks, never reallocs once warm

    let stream = device.build_output_stream(
        &config,
        move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
            let frames = data.len() / channels;
            if mono.len() < frames {
                mono.resize(frames, 0.0);
            }
            let m = &mut mono[..frames];

            match engine.lock() {
                Ok(mut eng) => eng.process_block(m),
                Err(_) => m.fill(0.0),
            }

            for (i, frame) in data.chunks_mut(channels).enumerate() {
                for s in frame.iter_mut() {
                    *s = m[i];
                }
            }
        },
        err_fn,
        None,
    )?;

    stream.play()?;
    Ok(AudioOut {
        _stream: stream,
        sample_rate,
    })
}
