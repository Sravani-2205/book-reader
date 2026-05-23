package com.example.book_reader;

import android.content.Intent;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.example.book_reader/tts_service";

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("startService")) {
                    String sentence = call.argument("sentence");
                    Intent intent = new Intent(this, TtsService.class);
                    intent.putExtra("sentence", sentence);
                    intent.putExtra("action", "play");
                    startForegroundService(intent);
                    result.success(null);
                } else if (call.method.equals("stopService")) {
                    Intent intent = new Intent(this, TtsService.class);
                    intent.putExtra("action", "stop");
                    startService(intent);
                    result.success(null);
                } else {
                    result.notImplemented();
                }
            });
    }
}
