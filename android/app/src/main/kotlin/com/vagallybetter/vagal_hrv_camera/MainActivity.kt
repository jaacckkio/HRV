package com.vagallybetter.vagal_hrv_camera

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CameraControlPlugin.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }
}
