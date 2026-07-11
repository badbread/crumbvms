//! Session persistence at rest via Windows DPAPI (CryptProtectData), ported from
//! the Tauri desktop's `secret_encrypt`/`dpapi_protect`. The whole read → decrypt
//! / encrypt → write round-trip stays in Rust so the token is never held in
//! plaintext on disk and the Dart side needs no file/path plugins.
//!
//! DPAPI ties the ciphertext to the current Windows user account: another user
//! (or another machine) cannot decrypt it. The blob is stored under
//! `%APPDATA%\CrumbVMS\session.bin`.

use std::path::PathBuf;

/// Absolute path to the encrypted-session file, creating the parent dir.
fn session_path() -> Result<PathBuf, String> {
    let base = std::env::var("APPDATA")
        .or_else(|_| std::env::var("HOME"))
        .map_err(|_| "neither APPDATA nor HOME set".to_string())?;
    let dir = PathBuf::from(base).join("CrumbVMS");
    std::fs::create_dir_all(&dir).map_err(|e| format!("create config dir: {e}"))?;
    Ok(dir.join("session.bin"))
}

/// Encrypt `data` (a JSON session blob) with DPAPI and write it to the session
/// file, replacing any previous one.
pub fn save_session(data: String) -> Result<(), String> {
    let bytes = dpapi_protect(data.as_bytes())?;
    std::fs::write(session_path()?, bytes).map_err(|e| format!("write session: {e}"))
}

/// Read + decrypt the saved session, or `None` if there is none / it can't be
/// decrypted (wrong user, corrupt, or not present). Never errors — a bad or
/// missing session just means "not logged in".
pub fn load_session() -> Option<String> {
    let path = session_path().ok()?;
    let raw = std::fs::read(path).ok()?;
    let dec = dpapi_unprotect(&raw).ok()?;
    String::from_utf8(dec).ok()
}

/// Delete the saved session (logout / auth failure).
pub fn clear_session() -> Result<(), String> {
    let path = session_path()?;
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("remove session: {e}")),
    }
}

// ─── DPAPI (Windows) ─────────────────────────────────────────────────────────

#[cfg(windows)]
fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use winapi::um::dpapi::CryptProtectData;
    use winapi::um::winbase::LocalFree;
    use winapi::um::wincrypt::DATA_BLOB;

    let mut input = DATA_BLOB {
        cbData: u32::try_from(plaintext.len()).map_err(|_| "data too large".to_string())?,
        pbData: plaintext.as_ptr().cast_mut(),
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut input,
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err("CryptProtectData failed".to_string());
    }
    let out = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe { LocalFree(output.pbData.cast()) };
    Ok(out)
}

#[cfg(windows)]
fn dpapi_unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    use winapi::um::dpapi::CryptUnprotectData;
    use winapi::um::winbase::LocalFree;
    use winapi::um::wincrypt::DATA_BLOB;

    let mut input = DATA_BLOB {
        cbData: u32::try_from(ciphertext.len()).map_err(|_| "data too large".to_string())?,
        pbData: ciphertext.as_ptr().cast_mut(),
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err("CryptUnprotectData failed (wrong user, or not DPAPI data)".to_string());
    }
    let out = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe { LocalFree(output.pbData.cast()) };
    Ok(out)
}

// Non-Windows fallback: store as-is (the client targets Windows; this keeps the
// crate building on other hosts for `cargo check`/CI).
#[cfg(not(windows))]
fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    Ok(plaintext.to_vec())
}

#[cfg(not(windows))]
fn dpapi_unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    Ok(ciphertext.to_vec())
}
