use raylib::prelude::*;

use crate::audio::{Context, Delay, Sample};
use crate::input::{Event, Key};
use crate::interface::draw_text_centered;
use crate::theme::{COLOR1, COLOR2, COLOR3};

use super::{Action, Knob, nudge};

pub struct DelayPlugin {
    dsp: Delay,
}

impl DelayPlugin {
    pub(super) fn new() -> Self {
        Self {
            dsp: Delay::new(48_000),
        }
    }

    pub(super) fn process(&mut self, ctx: &Context, buf: &mut [Sample]) {
        for sample in buf {
            *sample = self.dsp.process(ctx, *sample);
        }
    }
}

pub struct DelayPluginUi {
    delay_time: Knob,
    feedback: Knob,
    mix: Knob,
}

impl DelayPluginUi {
    pub(super) fn new() -> Self {
        Self {
            delay_time: Knob::new(32.0, 32.0, COLOR1, "delay_time"),
            feedback: Knob::new(96.0, 32.0, COLOR2, "feedback"),
            mix: Knob::new(32.0, 96.0, COLOR3, "mix"),
        }
    }

    pub(super) fn handle_event(&mut self, plugin: &mut DelayPlugin, event: Event) -> Action {
        match event.key {
            Key::Backspace => return Action::GoBack,
            Key::One => nudge(&mut plugin.dsp.delay_time, -0.1),
            Key::Two => nudge(&mut plugin.dsp.delay_time, 0.1),
            Key::Three => nudge(&mut plugin.dsp.feedback, -0.1),
            Key::Four => nudge(&mut plugin.dsp.feedback, 0.1),
            Key::Five => nudge(&mut plugin.dsp.mix, -0.1),
            Key::Six => nudge(&mut plugin.dsp.mix, 0.1),
            _ => {}
        }
        Action::None
    }

    pub(super) fn render<D: RaylibDraw>(&self, plugin: &DelayPlugin, d: &mut D) {
        self.delay_time.render(d, &plugin.dsp.delay_time);
        self.feedback.render(d, &plugin.dsp.feedback);
        self.mix.render(d, &plugin.dsp.mix);
        draw_text_centered(d, "DELAY", 64, 64, 10, Color::PURPLE);
    }
}
