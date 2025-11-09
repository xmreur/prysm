# Keep all classes in org.torproject.jni package
-keep class org.torproject.jni.** { *; }

# Keep native methods (important for JNI bindings)
-keepclassmembers class * {
    native <methods>;
}

# Keep specific fields that JNI accesses (like torConfiguration)
-keepclassmembers class org.torproject.jni.TorService {
    long torConfiguration;
}
