// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import android.content.Context
import android.net.ConnectivityManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.Inet4Address
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** A Crumb server found on the local network. */
data class DiscoveredServer(
    val url: String,
    val ip: String,
    val port: Int,
    val version: String?,
)

/**
 * Max probes in flight at once — bounds socket pressure so a /24 finishes in a
 * few seconds. Each host now gets [candidatePorts] probes (2 by default, 4 with
 * an explicit extra port), so this is doubled from the old single-candidate 48
 * to keep total scan time roughly the same.
 */
private const val SCAN_CONCURRENCY = 96

/**
 * Scan the device's local /24 for Crumb servers by probing the unauthenticated
 * `GET /health` endpoint and matching the server's `"service":"crumb-api"`
 * signature.
 *
 * Each host is probed on a small candidate set — plain HTTP :8080 *and* Caddy
 * TLS :8443 — so a TLS-only or dual-exposed server is found too (the old
 * behaviour probed only http:8080 and missed anything behind Caddy). An explicit
 * [port] is additionally probed on both schemes.
 *
 * Uses a **unicast TCP scan**, not mDNS, on purpose: the Crumb API runs in a
 * bridged Docker container, so multicast service discovery never reaches the LAN
 * — but ordinary TCP to the published port routes fine (the same reason the
 * server-side camera discovery is unicast).
 */
suspend fun discoverCrumbServers(
    context: Context,
    port: Int? = null,
    range: String? = null,
): List<DiscoveredServer> = withContext(Dispatchers.IO) {
    // `range` (a CIDR/base/dash/single) lets the user scan a DIFFERENT subnet than
    // the phone's own — needed when clients and the server live on separate VLANs
    // (the auto path only covers the device's /24). Null ⇒ scan the local /24.
    val hosts = (if (range.isNullOrBlank()) localSubnetHosts(context) else parseScanHosts(range))
        ?: return@withContext emptyList()
    if (hosts.isEmpty()) return@withContext emptyList()

    val plainClient = OkHttpClient.Builder()
        .connectTimeout(500, TimeUnit.MILLISECONDS)
        .readTimeout(800, TimeUnit.MILLISECONDS)
        .callTimeout(1500, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(false)
        .build()
    // TLS probe client that accepts self-signed/invalid certs. This is SCOPED
    // STRICTLY to the discovery /health fingerprint probe (a LAN Crumb server
    // behind Caddy typically has a self-signed cert): it is a local variable of
    // this function, never stored, and never used by the app's real API client —
    // login and all authenticated traffic keep full certificate validation.
    val tlsProbeClient = trustAllForDiscovery(plainClient)

    val candidates = candidatePorts(port)
    val gate = Semaphore(SCAN_CONCURRENCY)
    val found = coroutineScope {
        hosts.flatMap { ip ->
            candidates.map { (https, p) ->
                async {
                    gate.withPermit {
                        probe(if (https) tlsProbeClient else plainClient, https, ip, p)
                    }
                }
            }
        }.awaitAll()
    }.filterNotNull()

    collapseDualExposed(found)
        .sortedWith(
            compareBy(
                { it.ip.substringAfterLast('.').toIntOrNull() ?: 0 },
                { it.port },
            ),
        )
}

/**
 * The (isHttps, port) probe candidates per host: plain :8080 + TLS :8443, plus an
 * explicit user [port] on both schemes when it isn't one of the defaults.
 */
internal fun candidatePorts(port: Int?): List<Pair<Boolean, Int>> {
    val candidates = mutableListOf(false to 8080, true to 8443)
    if (port != null && candidates.none { it.second == port }) {
        candidates.add(false to port)
        candidates.add(true to port)
    }
    return candidates
}

/**
 * Collapse the plain+TLS front doors of a *single* host into one entry: when the
 * same IP answered on BOTH http:8080 and https:8443 it's one dual-exposed server,
 * so keep only the secure URL. Distinct IPs and genuinely different ports stay
 * separate entries.
 */
internal fun collapseDualExposed(found: List<DiscoveredServer>): List<DiscoveredServer> {
    val dual = found
        .filter { it.port == 8443 && it.url.startsWith("https://") }
        .map { it.ip }
        .toSet()
    return found.filterNot {
        it.port == 8080 && it.url.startsWith("http://") && it.ip in dual
    }
}

/**
 * A copy of [base] (sharing its dispatcher/connection pool) that accepts any TLS
 * certificate and hostname. ONLY for the unauthenticated discovery probe — never
 * use this for real API traffic.
 */
private fun trustAllForDiscovery(base: OkHttpClient): OkHttpClient {
    val trustAll = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
    val sslContext = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf(trustAll), SecureRandom())
    }
    return base.newBuilder()
        .sslSocketFactory(sslContext.socketFactory, trustAll)
        .hostnameVerifier { _, _ -> true }
        .build()
}

/**
 * The up-to-254 host IPs of the device's local /24 (last octet 1..254), excluding
 * the device's own address. Null when no IPv4 link address is available (e.g. no
 * active network). We scan the /24 regardless of the real prefix length: a wider
 * subnet still resolves its /24 here, and probing a few non-existent hosts is
 * cheap and bounded.
 */
private fun localSubnetHosts(context: Context): List<String>? {
    val self = selfIpv4(context) ?: return null
    val o = self.address
    val prefix = "${o[0].toInt() and 0xFF}.${o[1].toInt() and 0xFF}.${o[2].toInt() and 0xFF}"
    val selfLast = o[3].toInt() and 0xFF
    return (1..254).filter { it != selfLast }.map { "$prefix.$it" }
}

/** The device's primary site-local IPv4 (else any IPv4), or null when offline. */
private fun selfIpv4(context: Context): Inet4Address? {
    val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
    val net = cm.activeNetwork ?: return null
    val lp = cm.getLinkProperties(net) ?: return null
    val addrs = lp.linkAddresses.map { it.address }.filterIsInstance<Inet4Address>()
    return addrs.firstOrNull { it.isSiteLocalAddress } ?: addrs.firstOrNull()
}

/**
 * The device's own /24 as a CIDR string (e.g. `198.51.100.0/24`), for prefilling the
 * "scan a specific subnet" field so the user only has to change the third octet to
 * reach a server on a neighbouring VLAN. Null when offline.
 */
fun detectLocalSubnetCidr(context: Context): String? {
    val o = selfIpv4(context)?.address ?: return null
    return "${o[0].toInt() and 0xFF}.${o[1].toInt() and 0xFF}.${o[2].toInt() and 0xFF}.0/24"
}

/**
 * Parse a user-entered scan target into host IPs. Accepts a CIDR (scans that
 * address's /24), a `a.b.c` base (→ .1-254), a single `a.b.c.d`, or a dash range
 * (`a.b.c.10-20` / `a.b.c.10-a.b.c.20`). Bounded to ≤254 hosts; invalid ⇒ empty.
 */
private fun parseScanHosts(input: String): List<String> {
    val s = input.trim()
    if (s.isEmpty()) return emptyList()

    // CIDR — scan the /24 containing the address (covers the common /24 case).
    if (s.contains('/')) {
        val o = s.substringBefore('/').split('.').mapNotNull { it.toIntOrNull() }
        return if (o.size >= 3 && o.take(3).all { it in 0..255 }) {
            (1..254).map { "${o[0]}.${o[1]}.${o[2]}.$it" }
        } else {
            emptyList()
        }
    }

    // Dash range on the last octet (a.b.c.10-20 or a.b.c.10-a.b.c.20).
    if (s.contains('-')) {
        val lo = s.substringBefore('-').trim().split('.').mapNotNull { it.toIntOrNull() }
        val hiRaw = s.substringAfter('-').trim()
        val hiLast = hiRaw.toIntOrNull() ?: hiRaw.split('.').mapNotNull { it.toIntOrNull() }.lastOrNull()
        return if (lo.size == 4 && lo.all { it in 0..255 } &&
            hiLast != null && hiLast in lo[3]..255
        ) {
            (lo[3]..hiLast).map { "${lo[0]}.${lo[1]}.${lo[2]}.$it" }
        } else {
            emptyList()
        }
    }

    val o = s.split('.').mapNotNull { it.toIntOrNull() }
    return when {
        o.size == 3 && o.all { it in 0..255 } -> (1..254).map { "${o[0]}.${o[1]}.${o[2]}.$it" }
        o.size == 4 && o.all { it in 0..255 } -> listOf(s)
        else -> emptyList()
    }
}

/** Probe one host's `/health`; return a [DiscoveredServer] when it's a Crumb API. */
private fun probe(client: OkHttpClient, https: Boolean, ip: String, port: Int): DiscoveredServer? {
    val base = "${if (https) "https" else "http"}://$ip:$port"
    val body = httpGet(client, "$base/health") ?: return null
    // The /health body always carries "service":"crumb-api" (even when the DB is
    // degraded and it 503s), so it's the reliable Crumb fingerprint.
    if (!body.contains("crumb-api")) return null
    val version = httpGet(client, "$base/version")?.let { extractJsonString(it, "version") }
    return DiscoveredServer(url = base, ip = ip, port = port, version = version)
}

/** GET a URL and return the body for ANY response code (null only on a network
 *  error/timeout) — we identify Crumb by the body, not the status. */
private fun httpGet(client: OkHttpClient, url: String): String? = runCatching {
    client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
        resp.body?.string()
    }
}.getOrNull()

/** Minimal `"key":"value"` extractor so the scan doesn't pull in a JSON parser. */
private fun extractJsonString(json: String, key: String): String? {
    val re = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"([^\"]*)\"")
    return re.find(json)?.groupValues?.getOrNull(1)?.takeIf { it.isNotBlank() }
}
