package com.example.new_project

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 13+: the "warnings are on" notification of the background
        // GPS service only shows after the user allows notifications.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "speed_alert/notifications")
            .setMethodCallHandler { call, result ->
                if (call.method != "request") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < 33) {
                    result.success(true)
                    return@setMethodCallHandler
                }
                val permission = Manifest.permission.POST_NOTIFICATIONS
                val granted = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
                if (!granted) requestPermissions(arrayOf(permission), 7)
                result.success(granted)
            }
    }
}
