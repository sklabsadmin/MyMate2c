// The manifest declares the activity as ".MainActivity", which Android resolves
// against the Gradle namespace (com.aiboyfriend.mymate). The class used to live
// in com.iosappv2.ai_boyfriend_chat, a leftover from the project the app was
// cloned from, so every Android launch died with ClassNotFoundException before
// Flutter ever started. The package here must match the namespace.
package com.aiboyfriend.mymate

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
