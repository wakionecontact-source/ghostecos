package online.ghost_chat.ghost

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var wifiDirectPlugin: WifiDirectPlugin? = null
    private var blePeripheralPlugin: BlePeripheralPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiDirectPlugin = WifiDirectPlugin(this, flutterEngine)
        wifiDirectPlugin!!.register()

        blePeripheralPlugin = BlePeripheralPlugin(this, flutterEngine)
        blePeripheralPlugin!!.register()
    }
}
