//! Port of `midi.zig`.

use crate::input::Key;

pub type Frame = u64;

#[derive(Clone, Copy, Debug)]
pub struct Note {
    pub start: Frame,
    pub end: Frame,
    pub note: u8,
}

pub fn beats_to_frames(beats: f32, tempo: f32, sample_rate: f32) -> Frame {
    ((60.0 / tempo) * sample_rate * beats) as Frame
}

pub fn frames_to_beats(frames: Frame, tempo: f32, sample_rate: f32) -> f32 {
    frames as f32 / (sample_rate * 60.0 / tempo)
}

/// QWERTY -> MIDI note (one octave + black keys), mirrors `midi.keyToMidi`.
pub fn key_to_midi(key: Key) -> Option<u8> {
    use Key::*;
    Some(match key {
        // white keys (A–F row)
        A => 48,          // C3
        S => 50,          // D3
        D => 52,          // E3
        F => 53,          // F3
        G => 55,          // G3
        H => 57,          // A3
        J => 59,          // B3
        K => 60,          // C4
        L => 62,          // D4
        Semicolon => 64,  // E4
        Apostrophe => 65, // F4
        // black keys (W–P row)
        W => 49, // C#3
        E => 51, // D#3
        T => 54, // F#3
        Y => 56, // G#3
        U => 58, // A#3
        O => 61, // C#4
        P => 63, // D#4
        _ => return None,
    })
}
