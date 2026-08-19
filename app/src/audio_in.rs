use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::audio::Sample;
use crate::engine::Engine;

pub struct AudioIn {
    _stream: cpal::Stream,
}

pub fn start(engine: Arc<Mutex<Engine>>) -> Result<AudioIn, Box<dyn std::error::Error>> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or("no default input device")?;
    let supported = device.default_input_config()?;
    let sample_rate = supported.sample_rate().0 as f32;
    let channels = supported.channels() as usize;
    let config: cpal::StreamConfig = supported.clone().into();
    let err_fn = |error| eprintln!("audio input error: {error}");

    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |input: &[f32], _| record(&engine, input, channels, sample_rate, |sample| *sample),
            err_fn,
            None,
        )?,
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |input: &[i16], _| {
                record(&engine, input, channels, sample_rate, |sample| {
                    *sample as f32 / i16::MAX as f32
                });
            },
            err_fn,
            None,
        )?,
        cpal::SampleFormat::U16 => device.build_input_stream(
            &config,
            move |input: &[u16], _| {
                record(&engine, input, channels, sample_rate, |sample| {
                    (*sample as f32 / u16::MAX as f32) * 2.0 - 1.0
                });
            },
            err_fn,
            None,
        )?,
        format => {
            return Err(
                std::io::Error::other(format!("unsupported input format: {format:?}")).into(),
            );
        }
    };

    stream.play()?;
    Ok(AudioIn { _stream: stream })
}

fn record<T>(
    engine: &Arc<Mutex<Engine>>,
    input: &[T],
    channels: usize,
    sample_rate: f32,
    convert: impl Fn(&T) -> Sample,
) {
    if let Ok(mut engine) = engine.lock() {
        engine.record_audio_input(input, channels, sample_rate, convert);
    }
}
