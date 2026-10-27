package com.omergirgin.mosaic.core.connections

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Conservative JSON Schema subset checked before any model-prepared arguments are sent. */
object ConnectorSchema {
  fun validate(value: JsonElement, schema: JsonElement?, depth: Int = 0) {
    if (depth > 20 || ConnectorText.utf8Size(value.encoded) > 32_768) invalid()
    val allowed = schema["enum"].arrayValue
    if (allowed != null && allowed.none { it == value }) invalid()
    when (schema["type"].stringValue) {
      "object" -> {
        val obj = value as? JsonObject ?: invalid()
        val properties = schema["properties"].objectValue ?: JsonObject(emptyMap())
        val required = schema["required"].arrayValue?.mapNotNull { it.stringValue }.orEmpty()
        if (!required.all { obj.containsKey(it) }) invalid()
        if (schema["additionalProperties"].booleanValue == false && !properties.keys.containsAll(obj.keys)) invalid()
        for ((key, child) in obj) properties[key]?.let { validate(child, it, depth + 1) }
      }
      "array" -> {
        val array = value as? JsonArray ?: invalid()
        if (array.size > 200) invalid()
        for (child in array) validate(child, schema["items"], depth + 1)
      }
      "string" -> {
        val string = value.stringValue ?: invalid()
        val maximum = schema["maxLength"].numberValue ?: 16_384.0
        if (ConnectorText.utf8Size(string) > 16_384 || string.codePointCount(0, string.length) > maximum) invalid()
      }
      "number", "integer" -> {
        val number = value.numberValue ?: invalid()
        if (schema["type"].stringValue == "integer" && Math.rint(number) != number) invalid()
      }
      "boolean" -> if ((value as? JsonPrimitive)?.booleanValue == null) invalid()
      else -> Unit
    }
  }

  private fun invalid(): Nothing = throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
}
