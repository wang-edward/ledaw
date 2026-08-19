//! Polyphonic synth with an owned `Osc -> Lpf -> Adsr` chain per voice.

use raylib::prelude::*;

use crate::audio::{Adsr, AdsrStage, Context, Lpf, Osc, OscKind, Sample};
use crate::input::{Event, Key};
use crate::ui::Action;

const SYNTH_TUNING: f32 = 440.0;
const NUM_VOICES: usize = 16;

// TODO use note = Option<u8> instead
#[derive(Clone, Copy, PartialEq, Eq)]
enum NoteState {
    Off,
    On(u8),
}

struct Voice {
    osc: Osc,
    lpf: Lpf,
    adsr: Adsr,
    note_state: NoteState,
}

pub struct Juno {
    pub cutoff: f32,
    voices: Vec<Voice>,
    next_idx: usize,
}

pub struct JunoUi;

impl Voice {
    fn new(freq: f32) -> Self {
        Self {
            osc: Osc::new(freq, OscKind::Saw),
            lpf: Lpf::new(),
            adsr: Adsr::new(),
            note_state: NoteState::Off,
        }
    }

    fn next(&mut self, ctx: &Context) -> Sample {
        let sample = self.osc.next(ctx);
        let sample = self.lpf.process(ctx, sample);
        self.adsr.process(ctx, sample)
    }

    fn set_note_on(&mut self, note: u8) {
        self.note_state = NoteState::On(note);
        self.osc.reset_phase();
        self.osc.freq = note_to_freq(note);
        self.adsr.note_on();
    }

    fn set_note_off(&mut self, note: u8) {
        if let NoteState::On(on) = self.note_state
            && on == note
        {
            self.note_state = NoteState::Off;
            self.adsr.note_off();
        }
    }
}

impl Juno {
    pub fn new() -> Self {
        Self {
            cutoff: 5000.0,
            voices: (0..NUM_VOICES).map(|_| Voice::new(0.0)).collect(),
            next_idx: 0,
        }
    }

    fn find_free_voice(&mut self) -> Option<&mut Voice> {
        self.voices
            .iter_mut()
            .find(|v| v.note_state == NoteState::Off)
    }

    pub fn note_on(&mut self, note: u8) {
        if let Some(v) = self.find_free_voice() {
            v.set_note_on(note);
        } else {
            let idx = self.next_idx;
            self.next_idx = (self.next_idx + 1) % self.voices.len();
            self.voices[idx].set_note_on(note);
        }
    }

    pub fn note_off(&mut self, note: u8) {
        for v in &mut self.voices {
            v.set_note_off(note);
        }
    }

    pub fn all_notes_off(&mut self) {
        for v in &mut self.voices {
            if let NoteState::On(note) = v.note_state {
                v.set_note_off(note);
            }
        }
    }

    /// Sum all voices into `out`.
    pub fn process(&mut self, ctx: &Context, out: &mut [Sample]) {
        out.fill(0.0);
        let cutoff = self.cutoff;
        for v in &mut self.voices {
            v.lpf.cutoff.set(cutoff);
            for sample in out.iter_mut() {
                *sample += v.next(ctx);
            }
        }
    }

    /// True if every voice has fully released (used by tests/diagnostics).
    pub fn is_idle(&self) -> bool {
        self.voices.iter().all(|v| v.adsr.stage == AdsrStage::Idle)
    }
}

impl Default for Juno {
    fn default() -> Self {
        Self::new()
    }
}

impl JunoUi {
    pub fn new() -> Self {
        Self
    }

    pub fn handle_event(&mut self, _juno: &mut Juno, event: Event) -> Action {
        match event.key {
            Key::Backspace => Action::GoBack,
            _ => Action::None,
        }
    }

    pub fn render<D: RaylibDraw>(&self, _juno: &Juno, d: &mut D) {
        d.draw_text("JUNO", 0, 0, 5, Color::WHITE);
    }
}

impl Default for JunoUi {
    fn default() -> Self {
        Self::new()
    }
}

fn note_to_freq(note: u8) -> f32 {
    let semitone_offset = (note as i16 - 69) as f32;
    SYNTH_TUNING * (semitone_offset / 12.0).exp2()
}
