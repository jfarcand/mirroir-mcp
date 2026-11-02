// ABOUTME: Module index for the `.mirroir/` discovery, resolution, compose, and run pipeline.
// ABOUTME: Wraps the parser layer with filesystem semantics (locating, resolving, composing, replaying).

pub mod compose;
pub mod compose_cache;
pub mod compose_synth;
pub mod discover;
pub mod error;
pub mod git;
pub mod lock;
pub mod lock_checksum;
pub mod lock_freshness;
pub mod lock_generate;
pub mod pack_install;
pub mod resolve;
pub mod resolve_version;
pub mod run;
pub mod run_io;
pub mod run_selection;
