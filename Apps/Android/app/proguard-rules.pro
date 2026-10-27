# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class ** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.omergirgin.mosaic.**$$serializer { *; }
-keepclassmembers class com.omergirgin.mosaic.** { *** Companion; }

# ML Kit (on-device OCR) discovers its component registrars by reflection through
# MlKitInitProvider; R8 full mode would otherwise strip their no-arg constructors and OCR fails
# at runtime with "Could not instantiate ...Registrar".
-keep class * implements com.google.firebase.components.ComponentRegistrar { public <init>(); }
