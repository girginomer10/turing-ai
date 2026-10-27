package com.omergirgin.mosaic.core.connections

import java.net.URI
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** One pending public-client authorization (PKCE S256, exact redirect + state). Never persisted. */
class OAuthAttempt(
  val service: ConnectorId,
  val clientId: String,
  val authorizationEndpoint: String,
  val tokenEndpoint: String,
  val redirect: String,
  val scope: String,
  val resource: String?,
  val state: String,
  internal val verifier: String,
) {
  val challenge: String get() = ConnectorText.base64Url(ConnectorText.sha256(verifier))

  fun authorizationUrl(): String {
    val values = sortedMapOf(
      "response_type" to "code", "client_id" to clientId, "redirect_uri" to redirect,
      "state" to state, "code_challenge" to challenge, "code_challenge_method" to "S256",
    )
    if (scope.isNotEmpty()) values["scope"] = scope
    resource?.let { values["resource"] = it }
    if (service == ConnectorId.DROPBOX) values["token_access_type"] = "offline"
    if (service.isMicrosoft) values["prompt"] = "select_account"
    val separator = if ('?' in authorizationEndpoint) "&" else "?"
    return authorizationEndpoint + separator +
      values.entries.joinToString("&") { ConnectorText.percentEncode(it.key) + "=" + ConnectorText.percentEncode(it.value) }
  }

  /** The authorization code, only from the exact redirect with a single matching state and no error. */
  fun code(callback: String): String {
    val expected = runCatching { URI(redirect) }.getOrNull() ?: throw denied()
    val actual = runCatching { URI(callback) }.getOrNull() ?: throw denied()
    if (actual.scheme != expected.scheme || actual.rawAuthority != expected.rawAuthority ||
      actual.host != expected.host || actual.port != expected.port || actual.rawPath != expected.rawPath ||
      actual.rawUserInfo != null || actual.rawFragment != null
    ) {
      throw denied()
    }
    val items = ConnectorText.queryItems(actual.rawQuery) ?: throw denied()
    val states = items.filter { it.first == "state" }
    val codes = items.filter { it.first == "code" }
    val code = codes.singleOrNull()?.second
    if (states.size != 1 || states[0].second != state || items.any { it.first == "error" } ||
      code.isNullOrEmpty() || ConnectorText.utf8Size(code) > 4_096
    ) {
      throw denied()
    }
    return code
  }

  private fun denied() = ConnectorException(ConnectorException.Kind.DENIED)
}

/**
 * Provider-bound OAuth for hosted MCP (RFC 9728 resource metadata → RFC 8414 server metadata →
 * public dynamic client registration), Microsoft and Dropbox native PKCE. No client secret exists
 * anywhere in the app; every endpoint must stay on the provider's allowlisted hosts.
 */
object ConnectorOAuth {
  fun allowedHosts(service: ConnectorId): Set<String> {
    if (service.isMicrosoft) return setOf("login.microsoftonline.com")
    return when (service) {
      ConnectorId.LINEAR -> setOf("mcp.linear.app", "linear.app", "api.linear.app")
      ConnectorId.NOTION -> setOf("mcp.notion.com", "api.notion.com")
      ConnectorId.ATLASSIAN -> setOf("mcp.atlassian.com", "auth.atlassian.com")
      ConnectorId.CLOUDFLARE -> setOf("mcp.cloudflare.com")
      ConnectorId.DROPBOX -> setOf("www.dropbox.com", "api.dropboxapi.com")
      else -> emptySet()
    }
  }

  suspend fun prepare(service: ConnectorId, suppliedClientId: String, transport: ConnectorTransport): OAuthAttempt {
    if (!service.supportsOAuth) throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    val redirect = service.redirectUri
    var clientId = suppliedClientId.trim()
    val authorization: String
    val token: String
    var scope = ""
    var resource: String? = null
    val hosts = allowedHosts(service)
    if (service.isMicrosoft) {
      if (clientId.isEmpty() || runCatching { UUID.fromString(clientId) }.isFailure || clientId.length != 36) {
        throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      }
      authorization = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      token = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
      scope = "offline_access User.Read Mail.Read Calendars.Read Contacts.Read Tasks.Read Files.Read"
    } else if (service == ConnectorId.DROPBOX) {
      if (clientId.isEmpty() || clientId.length > 256 || !clientId.all { it.isLetterOrDigit() || it in "-_." }) {
        throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      }
      authorization = "https://www.dropbox.com/oauth2/authorize"
      token = "https://api.dropboxapi.com/oauth2/token"
      scope = "account_info.read files.metadata.read files.content.read"
    } else {
      val address = service.mcpUrl ?: throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      val endpoint = URI(address)
      val host = endpoint.host ?: throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      resource = address
      val origin = "https://$host"
      var issuer = origin
      // RFC 9728 path-specific metadata first; root metadata is the compatibility fallback.
      for (path in listOf("/.well-known/oauth-protected-resource" + endpoint.rawPath, "/.well-known/oauth-protected-resource")) {
        val response = transport.send(ConnectorRequest(origin + path), setOf(host), 32_768)
        if (response.status == 200) {
          val metadata = ConnectorJson.parse(response.body)
          val found = metadata["authorization_servers"].arrayValue?.firstOrNull()?.stringValue
          if (found != null) {
            if (!ConnectorHttp.isAllowed(found, hosts)) throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
            issuer = found
          }
          break
        }
      }
      val issuerUri = runCatching { URI(issuer) }.getOrNull()
      val issuerHost = issuerUri?.host ?: throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      val issuerPath = issuerUri.rawPath.orEmpty().let { if (it == "/") "" else it }
      val metadataUrl = "https://$issuerHost/.well-known/oauth-authorization-server$issuerPath"
      val metadata = ConnectorJson.parse(transport.send(ConnectorRequest(metadataUrl), hosts, 32_768).requireSuccess())
      val auth = metadata["authorization_endpoint"].stringValue
      val exchange = metadata["token_endpoint"].stringValue
      val methods = metadata["code_challenge_methods_supported"].arrayValue
      if (metadata["issuer"].stringValue?.trim('/') != issuer.trim('/') || auth == null || exchange == null ||
        !ConnectorHttp.isAllowed(auth, hosts) || !ConnectorHttp.isAllowed(exchange, hosts) ||
        (methods != null && methods.none { it.stringValue == "S256" })
      ) {
        throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      }
      authorization = auth
      token = exchange
      if (service == ConnectorId.LINEAR) scope = "read write"
      if (clientId.isEmpty()) {
        val registration = metadata["registration_endpoint"].stringValue
        if (registration == null || !ConnectorHttp.isAllowed(registration, hosts)) {
          throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
        }
        val body = jsonObject(
          "client_name" to JsonPrimitive("Turing AI"),
          "redirect_uris" to JsonArray(listOf(JsonPrimitive(redirect))),
          "grant_types" to JsonArray(listOf(JsonPrimitive("authorization_code"), JsonPrimitive("refresh_token"))),
          "response_types" to JsonArray(listOf(JsonPrimitive("code"))),
          "token_endpoint_auth_method" to JsonPrimitive("none"),
        )
        val registered = ConnectorJson.parse(transport.send(ConnectorRequest.json(registration, body), hosts, 32_768).requireSuccess())
        val id = registered["client_id"].stringValue
        val method = registered["token_endpoint_auth_method"].stringValue
        if (id.isNullOrEmpty() || ConnectorText.utf8Size(id) > 2_048 || (method != null && method != "none")) {
          throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
        }
        clientId = id
      }
    }
    return OAuthAttempt(
      service, clientId, authorization, token, redirect, scope, resource,
      state = ConnectorText.randomHex(), verifier = ConnectorText.randomHex(),
    )
  }

  suspend fun exchange(attempt: OAuthAttempt, callback: String, transport: ConnectorTransport, now: Long): ConnectorCredential {
    val fields = mutableMapOf(
      "grant_type" to "authorization_code", "code" to attempt.code(callback), "client_id" to attempt.clientId,
      "redirect_uri" to attempt.redirect, "code_verifier" to attempt.verifier,
    )
    attempt.resource?.let { fields["resource"] = it }
    val response = transport.send(ConnectorRequest.form(attempt.tokenEndpoint, fields), allowedHosts(attempt.service), 32_768)
    return credential(
      ConnectorJson.parse(response.requireSuccess()),
      ConnectorCredential(
        token = "", label = "Authorized account", clientId = attempt.clientId,
        tokenEndpoint = attempt.tokenEndpoint, resource = attempt.resource,
      ),
      now,
    )
  }

  /** Validated bearer token response; a returned refresh token replaces the old one (rotation). */
  fun credential(value: JsonElement, previous: ConnectorCredential, now: Long): ConnectorCredential {
    val access = value["access_token"].stringValue
    if (access.isNullOrEmpty() || ConnectorText.utf8Size(access) > 16_384 || access.any { it == '\n' || it == '\r' } ||
      value["token_type"].stringValue?.lowercase() != "bearer"
    ) {
      throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    }
    var refresh = previous.refreshToken
    value["refresh_token"].stringValue?.let {
      if (it.isEmpty() || ConnectorText.utf8Size(it) > 16_384) throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      refresh = it
    }
    val lifetime = value["expires_in"].numberValue ?: value["expires_in"].stringValue?.toDoubleOrNull()?.takeIf { it.isFinite() }
    val expiresAt = lifetime?.let { seconds ->
      if (seconds <= 0) throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      now + (minOf(seconds, 31_536_000.0) * 1_000).toLong()
    }
    return previous.copy(token = access, refreshToken = refresh, expiresAt = expiresAt)
  }
}
