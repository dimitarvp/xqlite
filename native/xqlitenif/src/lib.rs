use rustler::{Env, Term};

mod atoms;
mod close;
mod exec;
mod open;
mod pragma_get;
mod pragma_put;
mod query;
mod shared;

use crate::shared::XqliteConnection;

fn on_load(env: Env, _info: Term) -> bool {
    env.register::<XqliteConnection>().is_ok()
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
