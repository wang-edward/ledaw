use raylib::prelude::*;

use crate::audio::{Context, Lpf, Sample};
use crate::input::{Event, Key};
use crate::interface::draw_text_centered;
use crate::theme::{COLOR1, COLOR2, COLOR3};

use super::{Action, Knob, nudge};

pub struct LpfPlugin {
    dsp: Lpf,
}

impl LpfPlugin {
    pub(super) fn new() -> Self {
        Self { dsp: Lpf::new() }
    }

    pub(super) fn process(&mut self, ctx: &Context, buf: &mut [Sample]) {
        for sample in buf {
            *sample = self.dsp.process(ctx, *sample);
        }
    }
}

pub struct LpfPluginUi {
    drive: Knob,
    resonance: Knob,
    cutoff: Knob,
}

impl LpfPluginUi {
    pub(super) fn new() -> Self {
        Self {
            drive: Knob::new(32.0, 32.0, COLOR1, "drive"),
            resonance: Knob::new(96.0, 32.0, COLOR2, "resonance"),
            cutoff: Knob::new(32.0, 96.0, COLOR3, "cutoff"),
        }
    }

    pub(super) fn handle_event(&mut self, plugin: &mut LpfPlugin, event: Event) -> Action {
        match event.key {
            Key::Backspace => return Action::GoBack,
            Key::One => nudge(&mut plugin.dsp.drive, -0.1),
            Key::Two => nudge(&mut plugin.dsp.drive, 0.1),
            Key::Three => nudge(&mut plugin.dsp.resonance, -0.1),
            Key::Four => nudge(&mut plugin.dsp.resonance, 0.1),
            Key::Five => nudge(&mut plugin.dsp.cutoff, -0.1),
            Key::Six => nudge(&mut plugin.dsp.cutoff, 0.1),
            _ => {}
        }
        Action::None
    }

    pub(super) fn render<D: RaylibDraw>(&self, plugin: &LpfPlugin, d: &mut D) {
        self.drive.render(d, &plugin.dsp.drive);
        self.resonance.render(d, &plugin.dsp.resonance);
        self.cutoff.render(d, &plugin.dsp.cutoff);
        draw_text_centered(d, "LPF", 64, 64, 10, Color::GREEN);
    }
}
