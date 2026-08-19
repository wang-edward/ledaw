use std::path::{Path, PathBuf};

use raylib::prelude::*;

use crate::audio::{AudioBuffer, Context, Sample};
use crate::input::{Event, Key};
use crate::ui::Action;

const NUM_VOICES: usize = 8;

pub struct Sampler {
    sample: AudioBuffer,
    root_note: u8,
    voices: Vec<SamplerVoice>,
}
struct SamplerVoice {
    note: Option<u8>,
    position: f32,
}

impl Sampler {
    pub fn new(sample: AudioBuffer) -> Self {
        Self {
            sample,
            root_note: 60, // C3
            voices: (0..NUM_VOICES).map(|_| SamplerVoice::new()).collect(),
        }
    }

    pub fn set_sample(&mut self, sample: AudioBuffer) {
        self.all_notes_off();
        self.sample = sample;
    }

    pub fn note_on(&mut self, note: u8) {
        let Some(voice) = self.voices.iter_mut().find(|v| v.note.is_none()) else {
            return;
        };
        voice.note = Some(note);
        voice.position = 0.0;
    }
    pub fn note_off(&mut self, note: u8) {
        for v in &mut self.voices {
            if v.note == Some(note) {
                v.note = None;
            }
        }
    }
    pub fn all_notes_off(&mut self) {
        for v in &mut self.voices {
            v.note = None;
        }
    }
    fn next(&mut self, ctx: &Context) -> Sample {
        let mut ans: Sample = 0.0;
        for v in &mut self.voices {
            let Some(note) = v.note else { continue };
            let pitch_ratio = ((note as f32 - self.root_note as f32) / 12.0).exp2();
            let sample_rate_ratio = self.sample.sample_rate / ctx.sample_rate;
            let increment = pitch_ratio * sample_rate_ratio;

            let index = v.position.floor() as usize;
            if index + 1 >= self.sample.samples.len() {
                v.note = None;
                continue;
            }
            let fraction = v.position.fract();

            ans += self.sample.samples[index] * (1.0 - fraction)
                + self.sample.samples[index + 1] * fraction;
            v.position += increment;
        }
        ans
    }
    pub fn process(&mut self, ctx: &Context, out: &mut [Sample]) {
        for o in out.iter_mut() {
            *o = self.next(ctx);
        }
    }
}

impl Default for Sampler {
    fn default() -> Self {
        let sample = AudioBuffer::decode_wav(include_bytes!("../../assets/samples/choir.wav"));
        Self::new(sample)
    }
}

impl SamplerVoice {
    pub fn new() -> Self {
        SamplerVoice {
            note: None,
            position: 0f32,
        }
    }
}

pub enum SamplerScreen {
    Overview,
    Picker,
}
pub struct SamplerUi {
    screen: SamplerScreen,
    files: Vec<PathBuf>,
    selector_index: usize,
}

impl SamplerUi {
    pub fn new() -> Self {
        // TODO do something better on hardware
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/samples");
        let files = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "wav"))
            .collect();
        SamplerUi {
            screen: SamplerScreen::Overview,
            files,
            selector_index: 0,
        }
    }

    pub fn handle_event(&mut self, sampler: &mut Sampler, event: Event) -> Action {
        match self.screen {
            SamplerScreen::Overview => match event.key {
                Key::Backspace => return Action::GoBack,
                Key::R => self.screen = SamplerScreen::Picker,
                _ => {}
            },
            SamplerScreen::Picker => match event.key {
                Key::Backspace => self.screen = SamplerScreen::Overview,
                Key::K => self.selector_index = self.selector_index.saturating_sub(1),
                Key::J if self.selector_index + 1 < self.files.len() => {
                    self.selector_index += 1;
                }
                Key::Enter if !self.files.is_empty() => {
                    let path = &self.files[self.selector_index];
                    if let Ok(sample) = AudioBuffer::load_wav(path) {
                        sampler.set_sample(sample);
                        self.screen = SamplerScreen::Overview;
                    }
                }
                _ => {}
            },
        }
        Action::None
    }

    pub fn render<D: RaylibDraw>(&self, _sampler: &Sampler, d: &mut D) {
        match self.screen {
            SamplerScreen::Overview => {
                d.draw_text("OVERVIEW", 0, 0, 10, Color::WHITE);
            }
            SamplerScreen::Picker => {
                for (i, path) in self.files.iter().enumerate() {
                    let y = i as i32 * 16;

                    let color = if i == self.selector_index {
                        Color::RED
                    } else {
                        Color::BLUE
                    };

                    let name = path.file_name().unwrap().to_string_lossy();

                    d.draw_rectangle(0, y, 128, 16, Color::DARKGRAY);
                    d.draw_text(&name, 0, y, 5, color);
                }
            }
        }
    }
}

impl Default for SamplerUi {
    fn default() -> Self {
        Self::new()
    }
}
