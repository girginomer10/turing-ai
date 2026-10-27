plugins {
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.serialization)
  alias(libs.plugins.ksp)
}

android {
  namespace = "com.omergirgin.mosaic.data"
  compileSdk = 37
  defaultConfig {
    minSdk = 26
    consumerProguardFiles("consumer-rules.pro")
    // Public OAuth client registrations for device-direct connections (never client secrets).
    // Empty by default: those sign-ins stay disabled with an honest setup explanation until the
    // owner registers the app (Gradle property or environment variable of the same name).
    for (name in listOf("TURING_MICROSOFT_CLIENT_ID", "TURING_DROPBOX_CLIENT_ID")) {
      val value = (project.findProperty(name) as String?) ?: System.getenv(name) ?: ""
      require(value.all { it.isLetterOrDigit() || it in ".-_" }) { "$name contains unsupported characters." }
      buildConfigField("String", name, "\"$value\"")
    }
  }
  buildFeatures { buildConfig = true }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
}

ksp {
  arg("room.schemaLocation", "$projectDir/schemas")
  arg("room.generateKotlin", "true")
}

dependencies {
  api(project(":core"))
  implementation(libs.androidx.core.ktx)
  api(libs.room.runtime)
  implementation(libs.room.ktx)
  ksp(libs.room.compiler)
  implementation(libs.datastore.preferences)
  implementation(libs.work.runtime.ktx)
  implementation(libs.kotlinx.coroutines.android)
  // Document import: PDF text layer + on-device OCR (bundled Latin model, no model download).
  implementation(libs.pdfbox.android)
  implementation(libs.mlkit.text.recognition)
}
