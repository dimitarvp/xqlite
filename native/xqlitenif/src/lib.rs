use rustler::{Env, Term};

mod atoms;
mod close;
mod exec;
mod open;
mod pragma_get;
mod pragma_put;
mod query;
mod r2d2;
mod shared;

use crate::r2d2::XqliteConn;
use crate::shared::XqliteConnection;

fn on_load(env: Env, _info: Term) -> bool {
    env.register::<XqliteConn>().is_ok() && env.register::<XqliteConnection>().is_ok()
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
