package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import java.net.URI
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Where a credential may be sent. HTTPS is required everywhere except a trusted local network
 * (loopback, RFC 1918 private IPv4, `localhost`, and mDNS `.local` names), where local runtimes such
 * as Ollama or LM Studio usually serve plain HTTP. URLs carrying user info, a query, or a fragment
 * are rejected so the credential binding always names exactly one destination.
 */
object EndpointPolicy {
  /** Throws [com.omergirgin.mosaic.core.chat.ProviderException] (INVALID_ENDPOINT / INSECURE_ENDPOINT). */
  fun validate(baseUrl: String) {
    validatedBaseUrl(baseUrl)
  }

  /** iOS parity: no link-local (169.254/16) or IPv6 ULA ranges; those must use HTTPS. */
  fun isLocalHost(rawHost: String): Boolean {
    val host = rawHost.lowercase().trim('[', ']')
    if (host == "localhost" || host == "::1" || (host != ".local" && host.endsWith(".local"))) {
      return true
    }
    val components = host.split('.')
    if (components.size != 4) return false
    val octets =
      components.map { component ->
        if (component.isEmpty() || !component.all { it in '0'..'9' }) return false
        val value = component.toIntOrNull() ?: return false
        // Reject leading zeros: some resolvers read `010` as octal, changing the destination.
        if (value !in 0..255 || component != value.toString()) return false
        value
      }
    return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] in 16..31) ||
      (octets[0] == 192 && octets[1] == 168) ||
      octets[0] == 127
  }

  internal fun validatedBaseUrl(raw: String?): HttpUrl {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isEmpty()) throw ProviderFailures.of(ProviderErrorKind.INVALID_ENDPOINT)
    // CredentialBinding resolves endpoints with java.net.URI. Anything URI cannot resolve to a host
    // (spaces, underscores in host names, raw IDN) would bind its key to "unresolved", so it is
    // never a valid destination even if OkHttp's more lenient parser would accept it.
    val uri = runCatching { URI(trimmed) }.getOrNull()
    val scheme = uri?.scheme?.lowercase()
    if (uri == null || scheme == null || uri.host == null) {
      throw ProviderFailures.of(ProviderErrorKind.INVALID_ENDPOINT)
    }
    if (scheme != "http" && scheme != "https") {
      // A well-formed URL with another scheme is "insecure"; one carrying extra parts is invalid.
      val malformed = uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null
      throw ProviderFailures.of(
        if (malformed) ProviderErrorKind.INVALID_ENDPOINT else ProviderErrorKind.INSECURE_ENDPOINT
      )
    }
    val url = trimmed.toHttpUrlOrNull() ?: throw ProviderFailures.of(ProviderErrorKind.INVALID_ENDPOINT)
    if (
      url.encodedUsername.isNotEmpty() ||
        url.encodedPassword.isNotEmpty() ||
        url.encodedQuery != null ||
        url.encodedFragment != null ||
        url.host.isEmpty()
    ) {
      throw ProviderFailures.of(ProviderErrorKind.INVALID_ENDPOINT)
    }
    if (url.scheme == "https") return url
    if (url.scheme == "http" && isLocalHost(url.host)) return url
    throw ProviderFailures.of(ProviderErrorKind.INSECURE_ENDPOINT)
  }

  /** `base/path`, ignoring trailing slashes on the base (iOS `appending`). */
  internal fun appending(path: String, base: HttpUrl): HttpUrl =
    "${base.toString().trimEnd('/')}/$path".toHttpUrlOrNull()
      ?: throw ProviderFailures.of(ProviderErrorKind.INVALID_ENDPOINT)

  internal fun replacingPath(base: HttpUrl, encodedPath: String): HttpUrl =
    base.newBuilder().encodedPath(encodedPath).query(null).fragment(null).build()

  /** Percent-encoded path with trailing slashes trimmed (keeps `/` for the root). */
  internal fun trimmedEncodedPath(url: HttpUrl): String {
    var path = url.encodedPath
    while (path.length > 1 && path.endsWith("/")) path = path.dropLast(1)
    return path
  }

  /** Exact official HTTPS origin and path; used to unlock vendor-specific catalog routes. */
  internal fun isExactOfficialEndpoint(url: HttpUrl, host: String, encodedPath: String): Boolean =
    url.scheme == "https" && url.host == host && url.port == 443 && trimmedEncodedPath(url) == encodedPath

  /** One path segment (a model ID) with `/`, `?` and `#` escaped so it cannot change the route. */
  internal fun encodedPathSegment(value: String): String {
    if (value.isEmpty()) throw ProviderFailures.of(ProviderErrorKind.MISSING_MODEL)
    return percentEncode(value) { codePoint ->
      codePoint < 0x80 &&
        (Character.isLetterOrDigit(codePoint) || codePoint.toChar() in "!$&'()*+,-.:;=@_~")
    }
  }
}

/** Percent-encodes every UTF-8 byte of code points that [isAllowed] rejects. */
internal fun percentEncode(
  value: String,
  lowercaseHex: Boolean = false,
  isAllowed: (Int) -> Boolean,
): String {
  val digits = if (lowercaseHex) "0123456789abcdef" else "0123456789ABCDEF"
  val output = StringBuilder(value.length)
  value.codePoints().forEach { codePoint ->
    if (isAllowed(codePoint)) {
      output.appendCodePoint(codePoint)
    } else {
      for (byte in String(Character.toChars(codePoint)).encodeToByteArray()) {
        val unsigned = byte.toInt() and 0xFF
        output.append('%').append(digits[unsigned shr 4]).append(digits[unsigned and 0x0F])
      }
    }
  }
  return output.toString()
}
