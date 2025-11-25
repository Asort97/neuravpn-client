package com.example.happycat_vpnclient

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.happycat_vpnclient.vpn.LibboxVpnService

class MainActivity : FlutterActivity() {

	private var pendingPrepareResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				METHOD_PREPARE -> handlePrepareVpn(result)
				METHOD_START -> {
					val config = call.argument<String>(ARG_CONFIG)
					val includePackages = call.argument<List<String>>(ARG_INCLUDE_PACKAGES)
					val excludePackages = call.argument<List<String>>(ARG_EXCLUDE_PACKAGES)
					if (config.isNullOrBlank()) {
						result.error("INVALID_CONFIG", "Config payload required", null)
					} else {
						LibboxVpnService.start(applicationContext, config, includePackages, excludePackages)
						result.success(null)
					}
				}
				METHOD_STOP -> {
					LibboxVpnService.stop(applicationContext)
					result.success(null)
				}
				METHOD_STATUS -> {
					result.success(LibboxVpnService.isRunning())
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun handlePrepareVpn(result: MethodChannel.Result) {
		val intent = VpnService.prepare(this)
		if (intent == null) {
			result.success(true)
			return
		}
		if (pendingPrepareResult != null) {
			result.error("BUSY", "Another VPN permission request in progress", null)
			return
		}
		pendingPrepareResult = result
		startActivityForResult(intent, REQUEST_PREPARE_VPN)
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode == REQUEST_PREPARE_VPN) {
			val granted = resultCode == Activity.RESULT_OK
			pendingPrepareResult?.success(granted)
			pendingPrepareResult = null
		}
	}

	companion object {
		private const val CHANNEL = "happycat.vpn/native"
		private const val METHOD_PREPARE = "prepareVpn"
		private const val METHOD_START = "startVpn"
		private const val METHOD_STOP = "stopVpn"
		private const val METHOD_STATUS = "getVpnStatus"
		private const val ARG_CONFIG = "config"
		private const val ARG_INCLUDE_PACKAGES = "includePackages"
		private const val ARG_EXCLUDE_PACKAGES = "excludePackages"
		private const val REQUEST_PREPARE_VPN = 1001
	}
}
