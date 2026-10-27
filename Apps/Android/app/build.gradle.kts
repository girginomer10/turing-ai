import java.util.Properties

plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.kotlin.compose)
  alias(libs.plugins.kotlin.serialization)
}

// Release signing material lives outside the repository (never commit it). Point
// TURING_SIGNING_PROPERTIES at a properties file with storeFile/storePassword/keyAlias/keyPassword;
// the default is ~/.android/turing-release.properties. Without it, release builds stay unsigned.
val signingProperties = Properties().apply {
  val path = System.getenv("TURING_SIGNING_PROPERTIES")
    ?: "${System.getProperty("user.home")}/.android/turing-release.properties"
  val file = File(path)
  if (file.isFile) file.inputStream().use(::load)
}

android {
  namespace = "com.omergirgin.mosaic"
  compileSdk = 37

  defaultConfig {
    // Matches the iOS bundle identifier; the product name is Turing AI.
    applicationId = "com.omergirgin.mosaic"
    minSdk = 26
    targetSdk = 36
    versionCode = 3
    versionName = "0.1.0"
  }

  signingConfigs {
    if (signingProperties.getProperty("storeFile") != null) {
      create("release") {
        storeFile = File(signingProperties.getProperty("storeFile"))
        storePassword = signingProperties.getProperty("storePassword")
        keyAlias = signingProperties.getProperty("keyAlias")
        keyPassword = signingProperties.getProperty("keyPassword")
      }
    }
  }

  buildTypes {
    release {
      signingConfigs.findByName("release")?.let { signingConfig = it }
      isMinifyEnabled = true
      isShrinkResources = true
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  buildFeatures {
    compose = true
    buildConfig = true
  }

  // ML Kit OCR ships a large native library per ABI; per-ABI APKs keep a phone download small.
  // Install `app-arm64-v8a-release.apk` on modern phones (x86_64 is for emulators).
  splits {
    abi {
      isEnable = true
      reset()
      include("arm64-v8a", "armeabi-v7a", "x86_64")
      isUniversalApk = false
    }
  }

  packaging {
    resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/LICENSE*", "/META-INF/NOTICE*")
  }
}

dependencies {
  implementation(project(":data"))
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.activity.compose)
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)
  implementation(libs.androidx.lifecycle.process)
  implementation(libs.androidx.navigation.compose)

  implementation(platform(libs.compose.bom))
  implementation(libs.compose.ui)
  implementation(libs.compose.ui.tooling.preview)
  implementation(libs.compose.material3)
  implementation(libs.compose.material.icons.extended)
  debugImplementation(libs.compose.ui.tooling)

  implementation(libs.datastore.preferences)
  implementation(libs.work.runtime.ktx)
  implementation(libs.kotlinx.coroutines.android)
  implementation(libs.kotlinx.serialization.json)
  implementation(libs.okhttp)
  implementation(libs.markdown.renderer.m3)
  // Connections: OAuth browser leg in a Custom Tab (redirect returns to OAuthRedirectActivity).
  implementation(libs.androidx.browser)
  implementation(libs.androidx.exifinterface)
}
