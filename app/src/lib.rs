//! ledaw — Rust port of the Zig groovebox engine.
//!
//! The modules below are the portable, dependency-free DSP/data core and are
//! compiled + tested here. The FFI/UI layers (interface, oled, plugin, project, main)
//! live in their own files and depend on external crates (raylib, soundio, spidev/gpiod);
//! see notes in those files.

pub mod audio;
pub mod audio_in;
pub mod audio_out;
pub mod engine;
pub mod input;
pub mod instrument;
pub mod midi;
pub mod plugin;
pub mod theme;

pub mod interface;
pub mod ui;

#[cfg(test)]
mod tests {
    use crate::audio::Context;
    use crate::instrument::juno::Juno;
    use crate::instrument::sampler::Sampler;
    use crate::midi::{self, Note};

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 256;

    #[test]
    fn synth_produces_finite_audio_and_releases() {
        let ctx = Context::new(SR, 120.0);
        let mut synth = Juno::new();
        let mut out = vec![0.0; BLOCK];

        synth.note_on(69); // A4
        synth.note_on(72);

        let mut peak = 0.0f32;
        for _ in 0..50 {
            synth.process(&ctx, &mut out);
            for &s in out.iter() {
                assert!(s.is_finite(), "non-finite sample");
                peak = peak.max(s.abs());
            }
        }
        assert!(peak > 0.0, "synth was silent");

        synth.note_off(69);
        synth.note_off(72);
        // run long enough for the 0.6s release to finish
        for _ in 0..(SR as usize / BLOCK + 200) {
            synth.process(&ctx, &mut out);
        }
        assert!(synth.is_idle(), "voices never returned to idle");
    }

    #[test]
    fn sampler_produces_audio() {
        let ctx = Context::new(SR, 120.0);
        let mut sampler = Sampler::default();
        let mut out = vec![0.0; BLOCK];

        sampler.note_on(60);
        let mut peak = 0.0f32;
        for _ in 0..400 {
            sampler.process(&ctx, &mut out);
            peak = peak.max(out.iter().fold(0.0, |peak, sample| peak.max(sample.abs())));
        }

        assert!(out.iter().all(|sample| sample.is_finite()));
        assert!(peak > 0.0, "sampler was silent");
    }

    #[test]
    fn engine_clears_released_sampler_audio() {
        use crate::engine::{Engine, Track, TrackSource};
        use crate::instrument::Instrument;

        let mut engine = Engine::new(SR, 120.0);
        engine.add_track(Track::new(TrackSource::Instrument {
            instrument: Instrument::Sampler(Sampler::default()),
            notes: Vec::new(),
        }));
        let mut out = vec![0.0; BLOCK];

        engine.note_on(60);
        let mut peak = 0.0f32;
        for _ in 0..400 {
            engine.process_block(&mut out);
            peak = peak.max(out.iter().fold(0.0, |peak, sample| peak.max(sample.abs())));
        }
        assert!(peak > 0.0);

        engine.note_off(60);
        engine.process_block(&mut out);
        assert!(out.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn audio_clip_plays_only_while_transport_runs() {
        use crate::audio::AudioBuffer;
        use crate::engine::{AudioClip, Engine, Track, TrackSource};

        let audio = AudioBuffer::decode_wav(include_bytes!("../assets/samples/perfect.wav"));
        let mut engine = Engine::new(SR, 120.0);
        engine.add_track(Track::new(TrackSource::Audio {
            clips: vec![AudioClip::new(0, audio)],
        }));
        let mut out = vec![0.0; BLOCK];

        engine.process_block(&mut out);
        assert!(out.iter().all(|sample| *sample == 0.0));

        engine.toggle_play();
        engine.process_block(&mut out);
        assert!(out.iter().any(|sample| *sample != 0.0));
    }

    #[test]
    fn audio_recording_commits_to_the_starting_track() {
        use crate::engine::{Engine, Track, TrackSource};
        use crate::instrument::Instrument;

        let mut engine = Engine::new(SR, 120.0);
        engine.add_track(Track::new(TrackSource::Audio { clips: Vec::new() }));
        engine.add_track(Track::new(TrackSource::Instrument {
            instrument: Instrument::Sampler(Sampler::default()),
            notes: Vec::new(),
        }));

        engine.toggle_record();
        engine.set_active_track(1);
        engine.record_audio_input(&[0.25, -0.25, 0.5, 0.5], 2, 44_100.0, |sample| *sample);
        engine.toggle_record();

        let TrackSource::Audio { clips } = &engine.track(0).source else {
            panic!("recording destination was not an audio track");
        };
        assert_eq!(clips.len(), 1);
        assert_eq!(clips[0].start, 0);
        assert_eq!(clips[0].audio.sample_rate, 44_100.0);
        assert_eq!(clips[0].audio.samples, [0.0, 0.5]);
    }

    #[test]
    fn track_owns_its_notes() {
        use crate::engine::{Track, TrackSource};
        use crate::instrument::Instrument;

        let notes = [Note {
            start: 10,
            end: 100,
            note: 60,
        }];
        let track = Track::new(TrackSource::Instrument {
            instrument: Instrument::Sampler(Sampler::default()),
            notes: notes.to_vec(),
        });
        let TrackSource::Instrument { notes, .. } = track.source else {
            panic!("track source was not an instrument");
        };

        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].start, 10);
        assert_eq!(notes[0].end, 100);
        assert_eq!(notes[0].note, 60);
    }

    #[test]
    fn beats_frames_round_trip() {
        let f = midi::beats_to_frames(4.0, 120.0, SR);
        let b = midi::frames_to_beats(f, 120.0, SR);
        assert!((b - 4.0).abs() < 1e-3);
    }

    #[test]
    fn engine_two_track_demo_renders() {
        use crate::engine::{Engine, PluginKind, Track, TrackSource, create};
        use crate::instrument::Instrument;
        use crate::midi::{Note, beats_to_frames};
        let sr = SR;
        let mk = |b0: f32, b1: f32, n: u8| Note {
            start: beats_to_frames(b0, 120.0, sr),
            end: beats_to_frames(b1, 120.0, sr),
            note: n,
        };
        let lead = [mk(0.0, 0.9, 60), mk(1.0, 1.9, 67), mk(2.0, 2.9, 69)];
        let bass = [mk(0.0, 2.0, 48), mk(2.0, 4.0, 43)];

        let mut eng = Engine::new(sr, 120.0);
        eng.add_track(Track::new(TrackSource::Instrument {
            instrument: Instrument::Sampler(Sampler::default()),
            notes: lead.to_vec(),
        }));
        eng.add_track(Track::new(TrackSource::Instrument {
            instrument: Instrument::Sampler(Sampler::default()),
            notes: bass.to_vec(),
        }));
        let (lpf, _) = create(PluginKind::Lpf);
        let (delay, _) = create(PluginKind::Delay);
        eng.add_plugin(0, lpf);
        eng.add_plugin(1, delay);
        assert_eq!(eng.track_count(), 2);

        eng.toggle_play();
        let mut peak = 0.0f32;
        for _ in 0..400 {
            let out = ctx_block();
            // use engine-owned ctx via process_block
            let mut buf = vec![0.0f32; BLOCK];
            eng.process_block(&mut buf);
            for &s in &buf {
                assert!(s.is_finite());
                peak = peak.max(s.abs());
            }
            let _ = out;
        }
        assert!(peak > 0.0, "demo timeline produced silence");
    }

    fn ctx_block() -> usize {
        BLOCK
    }
}
