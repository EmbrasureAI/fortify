//! Compatibility names remain supported throughout the 0.x series.
use std::{env, ffi::OsString, path::PathBuf};

pub fn command_name() -> &'static str {
    if env::args_os()
        .next()
        .and_then(|arg| PathBuf::from(arg).file_stem().map(|s| s.to_owned()))
        .is_some_and(|name| name.eq_ignore_ascii_case("embrasure"))
    {
        "embrasure"
    } else {
        "fortify"
    }
}

pub fn config_path(explicit: Option<PathBuf>) -> PathBuf {
    explicit.unwrap_or_else(|| {
        let canonical = PathBuf::from("fortify-check.yml");
        let legacy = PathBuf::from("embrasure-check.yml");
        // An unreadable or invalid canonical file must not silently fall back.
        if canonical.symlink_metadata().is_ok() || !legacy.exists() {
            canonical
        } else {
            legacy
        }
    })
}

pub fn var_os(legacy: &str) -> Option<OsString> {
    lookup(legacy, |name| env::var_os(name))
}

fn lookup(legacy: &str, mut read: impl FnMut(&str) -> Option<OsString>) -> Option<OsString> {
    let canonical = legacy.replacen("EMBRASURE_", "FORTIFY_", 1);
    read(&canonical).or_else(|| read(legacy))
}

#[cfg(any(feature = "cloud-demo", test))]
pub fn var(legacy: &str) -> Result<String, env::VarError> {
    var_os(legacy)
        .ok_or(env::VarError::NotPresent)?
        .into_string()
        .map_err(env::VarError::NotUnicode)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_environment_wins_even_when_empty() {
        for canonical in ["new", ""] {
            assert_eq!(
                lookup("EMBRASURE_PYTHON", |name| match name {
                    "FORTIFY_PYTHON" => Some(canonical.into()),
                    "EMBRASURE_PYTHON" => Some("old".into()),
                    _ => None,
                }),
                Some(canonical.into())
            );
        }
    }

    #[test]
    fn legacy_environment_is_a_fallback() {
        assert_eq!(
            lookup("EMBRASURE_PYTHON", |name| {
                (name == "EMBRASURE_PYTHON").then(|| "old".into())
            }),
            Some("old".into())
        );
        assert_eq!(lookup("EMBRASURE_PYTHON", |_| None), None);
    }
}
