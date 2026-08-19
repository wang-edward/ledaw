use raylib::prelude::*;

use crate::audio::{Context, Param, Sample};
use crate::input::Event;
use crate::interface::draw_text_centered;
use crate::ui::Action;

mod delay_plugin;
mod lpf_plugin;

use delay_plugin::{DelayPlugin, DelayPluginUi};
use lpf_plugin::{LpfPlugin, LpfPluginUi};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PluginKind {
    Lpf,
    Delay,
}

pub const LIST: [PluginKind; 2] = [PluginKind::Lpf, PluginKind::Delay];

impl PluginKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Lpf => "lpf",
            Self::Delay => "delay",
        }
    }
}

pub enum Plugin {
    Lpf(LpfPlugin),
    Delay(DelayPlugin),
}

impl Plugin {
    pub fn kind(&self) -> PluginKind {
        match self {
            Self::Lpf(_) => PluginKind::Lpf,
            Self::Delay(_) => PluginKind::Delay,
        }
    }

    pub fn process(&mut self, ctx: &Context, buf: &mut [Sample]) {
        match self {
            Self::Lpf(plugin) => plugin.process(ctx, buf),
            Self::Delay(plugin) => plugin.process(ctx, buf),
        }
    }
}

pub struct Knob {
    pos: Vector2,
    radius: f32,
    color: Color,
    name: &'static str,
}

impl Knob {
    fn new(x: f32, y: f32, color: Color, name: &'static str) -> Self {
        Self {
            pos: Vector2::new(x, y),
            radius: 10.0,
            color,
            name,
        }
    }

    fn render<D: RaylibDraw>(&self, d: &mut D, param: &Param) {
        let angle = param.get_norm() * 360.0;
        d.draw_circle_sector(self.pos, self.radius, 0.0, angle, 360, self.color);
        draw_text_centered(
            d,
            self.name,
            self.pos.x as i32,
            (self.pos.y + 20.0) as i32,
            10,
            self.color,
        );
    }
}

pub enum PluginUi {
    Lpf(LpfPluginUi),
    Delay(DelayPluginUi),
}

impl PluginUi {
    pub fn handle_event(&mut self, plugin: &mut Plugin, event: Event) -> Action {
        match self {
            Self::Lpf(ui) => {
                let Plugin::Lpf(plugin) = plugin else {
                    debug_assert!(false, "Ui x Instrument mismatch");
                    return Action::None;
                };
                ui.handle_event(plugin, event)
            }
            Self::Delay(ui) => {
                let Plugin::Delay(plugin) = plugin else {
                    debug_assert!(false, "Ui x Instrument mismatch");
                    return Action::None;
                };
                ui.handle_event(plugin, event)
            }
        }
    }

    pub fn render<D: RaylibDraw>(&self, plugin: &Plugin, d: &mut D) {
        match self {
            Self::Lpf(ui) => {
                let Plugin::Lpf(plugin) = plugin else {
                    return;
                };
                ui.render(plugin, d)
            }
            Self::Delay(ui) => {
                let Plugin::Delay(plugin) = plugin else {
                    return;
                };
                ui.render(plugin, d)
            }
        }
    }
}

pub fn create(kind: PluginKind) -> (Plugin, PluginUi) {
    match kind {
        PluginKind::Lpf => (
            Plugin::Lpf(LpfPlugin::new()),
            PluginUi::Lpf(LpfPluginUi::new()),
        ),
        PluginKind::Delay => (
            Plugin::Delay(DelayPlugin::new()),
            PluginUi::Delay(DelayPluginUi::new()),
        ),
    }
}

fn nudge(param: &mut Param, delta: f32) {
    param.set_norm(param.get_norm() + delta);
}
