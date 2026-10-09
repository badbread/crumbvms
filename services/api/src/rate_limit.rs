// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-client token-bucket rate limiting, and the one place a request's client
//! address is derived ([`client_key`]).
//!
//! A dependency-free limiter: a `DashMap` of token buckets keyed by client IP.
//!
//! ## Client address
//!
//! By default the client is the **TCP peer IP**, the address the kernel
//! accepted the connection from. A client cannot choose it, and it is correct
//! for direct-to-Docker or LAN deployments.
//!
//! Behind a reverse proxy (the bundled Caddy, Nginx, Traefik, ...) every request
//! arrives from the proxy, so the peer alone would put every proxied user in one
//! bucket. Two settings change that:
//!
//! ```text
//! TRUST_PROXY=1
//! TRUSTED_PROXIES=caddy     # the default; comma-separated IPs, CIDRs or hostnames
//! ```
//!
//! With `TRUST_PROXY` set, `X-Forwarded-For` is read **only when the TCP peer
//! is one of `TRUSTED_PROXIES`**. A request that reaches the api any other way
//! (for example straight on the published `:8080`) is keyed on its own peer
//! address, whatever headers it carries. From a trusted peer the header chain
//! is walked from the right, the hop the proxy itself appended, past any further
//! trusted proxies; the first address that is not a trusted proxy is the client.
//! Entries to the left of it are whatever the original client sent and are
//! never used.
//!
//! Hostname entries are resolved at startup and again every
//! [`PROXY_RESOLVE_INTERVAL`], so the bundled Caddy is still recognised after
//! its container is recreated with a new address. A name that does not resolve
//! trusts nothing: requests from that proxy then key on the proxy's own address
//! (one shared bucket), never on a header.
//!
//! Both settings are read **once at startup** (into `ApiConfig`); there is no
//! runtime reload. The login backoff (`auth::login`) derives its client with the
//! same [`client_key`] and the same [`ProxyTrust`], so the two can never
//! disagree about who a request came from.
//!
//! ## Limiter
//!
//! Applied as an axum layer over the JSON routes only (auth/timeline/status/
//! config/views/ptz), NOT over media/segment serving, which is high-frequency
//! by nature during playback. The generous default (burst 240, ~4 req/s refill)
//! never bothers a normal operator but caps a runaway/abusive client. Rate-
//! limited responses return `429 Too Many Requests`.
//!
//! NOTE: the bucket map is not pruned; at homelab IP cardinality this is
//! negligible. Add a periodic sweep if ever exposed to the open internet.

use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, PoisonError, RwLock};
use std::time::{Duration, Instant};

use axum::{
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use dashmap::DashMap;
use serde_json::json;

/// `TRUSTED_PROXIES` when the variable is unset or empty: the bundled Caddy's
/// compose service name.
pub const DEFAULT_TRUSTED_PROXIES: &str = "caddy";

/// How often hostname entries in `TRUSTED_PROXIES` are re-resolved.
pub const PROXY_RESOLVE_INTERVAL: Duration = Duration::from_secs(30);

/// Read whether the `TRUST_PROXY` env var is set (any non-empty value enables
/// it). Read once at startup into `ApiConfig::trust_proxy`.
pub fn trust_proxy_from_env() -> bool {
    std::env::var("TRUST_PROXY").is_ok_and(|v| !v.trim().is_empty())
}

/// One `TRUSTED_PROXIES` address or CIDR block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct IpNet {
    addr: IpAddr,
    prefix: u8,
}

impl IpNet {
    /// Parse `192.0.2.7`, `192.0.2.0/24`, `2001:db8::1` or `2001:db8::/32`.
    fn parse(s: &str) -> Option<Self> {
        let (addr, prefix) = match s.split_once('/') {
            Some((a, p)) => (a, Some(p)),
            None => (s, None),
        };
        let addr = addr.trim().parse::<IpAddr>().ok()?.to_canonical();
        let max = if addr.is_ipv4() { 32 } else { 128 };
        let prefix = match prefix {
            Some(p) => p.trim().parse::<u8>().ok().filter(|p| *p <= max)?,
            None => max,
        };
        Some(Self { addr, prefix })
    }

    fn contains(&self, ip: IpAddr) -> bool {
        fn same_prefix(a: u128, b: u128, bits: u8, prefix: u8) -> bool {
            let shift = u32::from(bits - prefix);
            shift >= 128 || (a >> shift) == (b >> shift)
        }
        match (self.addr, ip.to_canonical()) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => same_prefix(
                u128::from(u32::from(net)),
                u128::from(u32::from(ip)),
                32,
                self.prefix,
            ),
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                same_prefix(u128::from(net), u128::from(ip), 128, self.prefix)
            }
            _ => false,
        }
    }
}

/// Which TCP peers may supply the client address in `X-Forwarded-For`.
///
/// Built once from `TRUST_PROXY` + `TRUSTED_PROXIES` and shared (via `Arc`) by
/// the request limiter and the login backoff.
#[derive(Debug)]
pub struct ProxyTrust {
    /// `TRUST_PROXY`. When false no header is ever read.
    enabled: bool,
    /// Literal addresses and CIDR blocks.
    nets: Vec<IpNet>,
    /// Hostnames, resolved by [`ProxyTrust::refresh`].
    hosts: Vec<String>,
    /// The current addresses of `hosts`.
    resolved: RwLock<Vec<IpAddr>>,
}

impl ProxyTrust {
    /// Build from the `TRUST_PROXY` flag and a `TRUSTED_PROXIES` list
    /// (comma-separated IPs, CIDRs or hostnames). An empty list means
    /// [`DEFAULT_TRUSTED_PROXIES`]. Malformed address or CIDR entries are
    /// logged and skipped; they never widen what is trusted.
    #[must_use]
    pub fn new(enabled: bool, trusted_proxies: &str) -> Self {
        let spec = if trusted_proxies.trim().is_empty() {
            DEFAULT_TRUSTED_PROXIES
        } else {
            trusted_proxies
        };
        let mut nets = Vec::new();
        let mut hosts = Vec::new();
        for entry in spec.split(',').map(str::trim).filter(|e| !e.is_empty()) {
            if let Some(net) = IpNet::parse(entry) {
                nets.push(net);
            } else if entry.contains('/') || entry.contains(':') {
                tracing::warn!(entry, "TRUSTED_PROXIES: ignoring malformed address or CIDR");
            } else {
                hosts.push(entry.to_owned());
            }
        }
        Self {
            enabled,
            nets,
            hosts,
            resolved: RwLock::new(Vec::new()),
        }
    }

    /// Whether `TRUST_PROXY` is on.
    #[must_use]
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Whether `ip` is a configured proxy (a literal, a CIDR member, or a
    /// current address of a configured hostname).
    #[must_use]
    pub fn is_trusted(&self, ip: IpAddr) -> bool {
        let ip = ip.to_canonical();
        self.nets.iter().any(|n| n.contains(ip))
            || self
                .resolved
                .read()
                .unwrap_or_else(PoisonError::into_inner)
                .contains(&ip)
    }

    /// Re-resolve the hostname entries. A name that fails to resolve
    /// contributes no addresses (fail closed: its traffic keys on the proxy's
    /// own address until it resolves again).
    pub async fn refresh(&self) {
        if !self.enabled || self.hosts.is_empty() {
            return;
        }
        let mut addrs = Vec::new();
        for host in &self.hosts {
            match tokio::net::lookup_host((host.as_str(), 0)).await {
                Ok(found) => addrs.extend(found.map(|a| a.ip().to_canonical())),
                Err(e) => {
                    tracing::debug!(host = %host, error = %e, "trusted proxy name did not resolve");
                }
            }
        }
        addrs.sort_unstable();
        addrs.dedup();
        let mut current = self
            .resolved
            .write()
            .unwrap_or_else(PoisonError::into_inner);
        if *current != addrs {
            tracing::info!(hosts = ?self.hosts, addresses = ?addrs, "trusted proxy addresses updated");
            *current = addrs;
        }
    }

    /// Keep hostname entries current: re-resolve every
    /// [`PROXY_RESOLVE_INTERVAL`]. A no-op when there is nothing to resolve.
    pub fn spawn_refresh(self: &Arc<Self>) {
        if !self.enabled || self.hosts.is_empty() {
            return;
        }
        let trust = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(PROXY_RESOLVE_INTERVAL);
            loop {
                tick.tick().await;
                trust.refresh().await;
            }
        });
    }
}

/// Parse one `X-Forwarded-For` hop: a bare address, or an `ip:port` /
/// `[v6]:port` / `[v6]` form some proxies emit.
fn parse_hop(hop: &str) -> Option<IpAddr> {
    let hop = hop.trim();
    let ip = hop
        .parse::<IpAddr>()
        .ok()
        .or_else(|| hop.parse::<SocketAddr>().ok().as_ref().map(SocketAddr::ip))
        .or_else(|| {
            hop.strip_prefix('[')
                .and_then(|h| h.strip_suffix(']'))
                .and_then(|h| h.parse::<IpAddr>().ok())
        })?;
    Some(ip.to_canonical())
}

/// The client address one request is attributed to (see the module docs).
///
/// - The TCP peer, unless `TRUST_PROXY` is on AND the peer is a trusted proxy.
/// - From a trusted proxy: the right-most `X-Forwarded-For` hop that is not
///   itself a trusted proxy. With no header, or a chain made only of trusted
///   proxies, the left-most trusted address seen. An unparseable hop stops the
///   walk at the last trusted address, so a malformed header can never select
///   an arbitrary value.
#[must_use]
pub fn client_ip(trust: &ProxyTrust, headers: &HeaderMap, peer: IpAddr) -> IpAddr {
    let peer = peer.to_canonical();
    if !trust.enabled || !trust.is_trusted(peer) {
        return peer;
    }
    let hops: Vec<&str> = headers
        .get_all("x-forwarded-for")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|s| s.split(','))
        .collect();
    let mut client = peer;
    for hop in hops.iter().rev() {
        let Some(ip) = parse_hop(hop) else {
            break;
        };
        client = ip;
        if !trust.is_trusted(ip) {
            break;
        }
    }
    client
}

/// The client key one request is attributed to, as a string: [`client_ip`] of
/// the peer.
///
/// `peer` is an `Option` because callers other than the middleware (the
/// `/auth/login` handler, which keys its own backoff on the same value) may run
/// in contexts with no `ConnectInfo` extension, e.g. a router driven directly in
/// a test. Those fall back to a single shared `"unknown-peer"` key rather than
/// silently keying on nothing.
///
/// This is the ONE place the client key is derived, so the limiter and the
/// login backoff can never drift apart on proxy handling.
#[must_use]
pub fn client_key(trust: &ProxyTrust, headers: &HeaderMap, peer: Option<SocketAddr>) -> String {
    peer.map_or_else(
        || "unknown-peer".to_owned(),
        |p| client_ip(trust, headers, p.ip()).to_string(),
    )
}

/// Shared token-bucket rate limiter.
pub struct RateLimiter {
    buckets: DashMap<String, Bucket>,
    /// Max tokens (burst capacity).
    capacity: f64,
    /// Tokens replenished per second (sustained rate).
    refill_per_sec: f64,
    /// Which peers may name the client in `X-Forwarded-For` (module docs).
    trust: Arc<ProxyTrust>,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    /// Create a shared limiter.
    ///
    /// - `capacity` = burst size (requests).
    /// - `refill_per_sec` = sustained requests/second per client.
    /// - `trust` = the shared [`ProxyTrust`] (`AppState::proxy_trust`), so this
    ///   limiter and the login backoff attribute requests identically.
    pub fn new(capacity: u32, refill_per_sec: f64, trust: Arc<ProxyTrust>) -> Arc<Self> {
        if trust.enabled() {
            tracing::info!(
                "rate limiter: TRUST_PROXY=1, reading X-Forwarded-For only from TRUSTED_PROXIES peers"
            );
        } else {
            tracing::info!("rate limiter: keying on TCP peer IP (TRUST_PROXY not set)");
        }
        Arc::new(Self {
            buckets: DashMap::new(),
            capacity: f64::from(capacity),
            refill_per_sec,
            trust,
        })
    }

    /// Consume one token for `key`. Returns `true` if allowed, `false` if the
    /// bucket is empty. Fully synchronous (no await while the entry is locked).
    fn check(&self, key: &str) -> bool {
        let now = Instant::now();
        let mut bucket = self.buckets.entry(key.to_owned()).or_insert(Bucket {
            tokens: self.capacity,
            last: now,
        });
        let elapsed = now.duration_since(bucket.last).as_secs_f64();
        bucket.last = now;
        bucket.tokens = (bucket.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

/// axum middleware (used via `from_fn_with_state`). Rejects with 429 when the
/// client's bucket is exhausted. The client is [`client_key`] of the request.
pub async fn rate_limit_mw(
    State(limiter): State<Arc<RateLimiter>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let key = client_key(&limiter.trust, req.headers(), Some(peer));

    if limiter.check(&key) {
        next.run(req).await
    } else {
        tracing::warn!(client = %key, "rate limit exceeded — returning 429");
        (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({
                "error": "Too Many Requests",
                "message": "rate limit exceeded; slow down"
            })),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::{client_ip, client_key, IpNet, ProxyTrust};
    use axum::http::{HeaderMap, HeaderValue};
    use std::net::{IpAddr, SocketAddr};

    const PROXY: &str = "192.0.2.10";
    const DIRECT: &str = "192.0.2.50";

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    fn xff(value: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", HeaderValue::from_str(value).unwrap());
        h
    }

    fn trust() -> ProxyTrust {
        ProxyTrust::new(true, PROXY)
    }

    #[test]
    fn header_from_a_peer_that_is_not_a_trusted_proxy_is_ignored() {
        // A client reaching the api directly with a forged header is keyed on
        // its own address, whatever the header says.
        let t = trust();
        for forged in ["198.51.100.1", "198.51.100.2, 198.51.100.3", PROXY] {
            assert_eq!(client_ip(&t, &xff(forged), ip(DIRECT)), ip(DIRECT));
        }
    }

    #[test]
    fn header_is_ignored_entirely_when_trust_proxy_is_off() {
        let t = ProxyTrust::new(false, PROXY);
        assert_eq!(
            client_ip(&t, &xff("198.51.100.1"), ip(PROXY)),
            ip(PROXY),
            "even the configured proxy's header is ignored with TRUST_PROXY unset"
        );
    }

    #[test]
    fn trusted_proxy_header_is_honoured() {
        let t = trust();
        assert_eq!(
            client_ip(&t, &xff("198.51.100.1"), ip(PROXY)),
            ip("198.51.100.1")
        );
    }

    #[test]
    fn right_most_untrusted_hop_wins_over_client_supplied_entries() {
        // The client sent "203.0.113.99" itself; the proxy appended the real
        // peer "198.51.100.1". Only the proxy's entry is believed.
        let t = trust();
        assert_eq!(
            client_ip(&t, &xff("203.0.113.99, 198.51.100.1"), ip(PROXY)),
            ip("198.51.100.1")
        );
    }

    #[test]
    fn chained_trusted_proxies_are_skipped() {
        let t = ProxyTrust::new(true, "192.0.2.10, 192.0.2.128/25");
        assert_eq!(
            client_ip(
                &t,
                &xff("203.0.113.99, 198.51.100.1, 192.0.2.200"),
                ip(PROXY)
            ),
            ip("198.51.100.1")
        );
    }

    #[test]
    fn multiple_header_lines_are_read_in_order() {
        let t = trust();
        let mut h = HeaderMap::new();
        h.append("x-forwarded-for", HeaderValue::from_static("203.0.113.99"));
        h.append("x-forwarded-for", HeaderValue::from_static("198.51.100.1"));
        assert_eq!(client_ip(&t, &h, ip(PROXY)), ip("198.51.100.1"));
    }

    #[test]
    fn unparseable_hop_falls_back_to_the_proxy_address() {
        let t = trust();
        assert_eq!(client_ip(&t, &xff("not-an-ip"), ip(PROXY)), ip(PROXY));
        assert_eq!(
            client_ip(&t, &xff("198.51.100.1, garbage"), ip(PROXY)),
            ip(PROXY),
            "the walk stops at the malformed right-most hop, it never skips it"
        );
        assert_eq!(client_ip(&t, &HeaderMap::new(), ip(PROXY)), ip(PROXY));
    }

    #[test]
    fn hop_forms_with_ports_and_brackets_parse() {
        let t = trust();
        assert_eq!(
            client_ip(&t, &xff("198.51.100.1:5555"), ip(PROXY)),
            ip("198.51.100.1")
        );
        assert_eq!(
            client_ip(&t, &xff("[2001:db8::7]:5555"), ip(PROXY)),
            ip("2001:db8::7")
        );
        assert_eq!(
            client_ip(&t, &xff("[2001:db8::7]"), ip(PROXY)),
            ip("2001:db8::7")
        );
    }

    #[test]
    fn ipv4_mapped_peer_matches_an_ipv4_entry() {
        let t = trust();
        assert_eq!(
            client_ip(&t, &xff("198.51.100.1"), ip("::ffff:192.0.2.10")),
            ip("198.51.100.1")
        );
    }

    #[test]
    fn cidr_matching() {
        let n = IpNet::parse("192.0.2.0/24").unwrap();
        assert!(n.contains(ip("192.0.2.1")));
        assert!(!n.contains(ip("192.0.3.1")));
        assert!(IpNet::parse("0.0.0.0/0")
            .unwrap()
            .contains(ip("203.0.113.1")));
        assert!(!IpNet::parse("0.0.0.0/0")
            .unwrap()
            .contains(ip("2001:db8::1")));
        let v6 = IpNet::parse("2001:db8::/32").unwrap();
        assert!(v6.contains(ip("2001:db8:1::1")));
        assert!(!v6.contains(ip("2001:db9::1")));
        assert!(IpNet::parse("192.0.2.0/33").is_none());
        assert!(IpNet::parse("192.0.2.0/x").is_none());
    }

    #[test]
    fn empty_list_means_the_bundled_caddy_name() {
        let t = ProxyTrust::new(true, "  ");
        assert_eq!(t.hosts, vec!["caddy".to_owned()]);
        assert!(t.nets.is_empty());
        // Unresolved, the name trusts nothing.
        assert_eq!(client_ip(&t, &xff("198.51.100.1"), ip(PROXY)), ip(PROXY));
    }

    #[test]
    fn malformed_entries_are_skipped_not_widened() {
        let t = ProxyTrust::new(true, "192.0.2.0/99, 2001:db8::zz, 192.0.2.10");
        assert_eq!(t.nets.len(), 1);
        assert!(t.hosts.is_empty());
        assert!(!t.is_trusted(ip("192.0.2.11")));
    }

    #[test]
    fn client_key_without_a_peer_is_the_shared_unknown_key() {
        let t = trust();
        assert_eq!(client_key(&t, &xff("198.51.100.1"), None), "unknown-peer");
        let peer: SocketAddr = "192.0.2.50:4000".parse().unwrap();
        assert_eq!(client_key(&t, &xff("198.51.100.1"), Some(peer)), DIRECT);
    }

    #[tokio::test]
    async fn hostname_entries_resolve_on_refresh() {
        let t = ProxyTrust::new(true, "localhost");
        assert!(
            !t.is_trusted(ip("127.0.0.1")) && !t.is_trusted(ip("::1")),
            "nothing trusted before resolving"
        );
        t.refresh().await;
        assert!(
            t.is_trusted(ip("127.0.0.1")) || t.is_trusted(ip("::1")),
            "localhost resolves to a loopback address"
        );
    }
}
