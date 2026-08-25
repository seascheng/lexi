//! Process-wide shared `reqwest::Client`.
//!
//! `reqwest::Client` owns the connection pool, TLS session cache, and HTTP/2
//! state. Constructing one per request throws all of that away and forces every
//! call to repeat DNS + TCP + TLS handshakes (hundreds of ms of latency before
//! the model emits a single token). The Client is cheap to clone (it is an
//! `Arc` internally), so we build one lazily and reuse it everywhere.

use std::sync::LazyLock;
use std::time::Duration;

static HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        // Cap only the connection-setup phase so a dead endpoint fails fast;
        // the response itself (which can be slow for LLM/TTS streaming) is
        // left unbounded.
        .connect_timeout(Duration::from_secs(15))
        // Keep idle connections warm so subsequent requests skip the
        // DNS/TCP/TLS handshake entirely — the main latency win.
        .pool_idle_timeout(Duration::from_secs(90))
        .pool_max_idle_per_host(4)
        // Disable Nagle's algorithm: small SSE chunks reach the UI immediately
        // instead of waiting to be coalesced.
        .tcp_nodelay(true)
        .build()
        .expect("failed to build shared reqwest client")
});

/// Returns a clone of the shared HTTP client.
///
/// Cloning only bumps an `Arc` refcount; the underlying connection pool is
/// shared. Use this instead of `reqwest::Client::new()` on any request path.
pub fn http_client() -> reqwest::Client {
    HTTP_CLIENT.clone()
}
