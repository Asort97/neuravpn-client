package com.neuravpn.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.neuravpn.app.vpn.AndroidVpnRuntimeManager
import com.neuravpn.app.vpn.XrayVpnService

class MainActivity : FlutterActivity() {

	private var pendingPrepareResult: MethodChannel.Result? = null
	private var pendingLaunchUri: String? = null
	private var launchChannel: MethodChannel? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				METHOD_PREPARE -> handlePrepareVpn(result)
				METHOD_START -> {
					try {
						val config = call.argument<String>(ARG_CONFIG)
						val runtime = call.argument<String>(ARG_RUNTIME)
						val executablePath = call.argument<String>(ARG_EXECUTABLE_PATH)
						val includePackages = call.argument<List<String>>(ARG_INCLUDE_PACKAGES)
						val excludePackages = call.argument<List<String>>(ARG_EXCLUDE_PACKAGES)
						if (config.isNullOrBlank()) {
							result.error("INVALID_CONFIG", "Config payload required", null)
						} else {
							// Save config for Quick Settings Tile before starting
							XrayVpnService.saveLastConfig(
								applicationContext, config, executablePath,
								includePackages, excludePackages,
							)
							AndroidVpnRuntimeManager.start(
								context = applicationContext,
								runtimeId = runtime,
								config = config,
								executablePath = executablePath,
								includePackages = includePackages,
								excludePackages = excludePackages,
							)
							result.success(null)
						}
					} catch (t: Throwable) {
						result.error("START_VPN_FAILED", t.message, null)
					}
				}
				METHOD_STOP -> {
					try {
						AndroidVpnRuntimeManager.stop(applicationContext, null)
						result.success(null)
					} catch (t: Throwable) {
						result.error("STOP_VPN_FAILED", t.message, null)
					}
				}
				METHOD_STATUS -> {
					try {
						result.success(AndroidVpnRuntimeManager.isRunning(applicationContext))
					} catch (t: Throwable) {
						result.error("STATUS_VPN_FAILED", t.message, null)
					}
				}
				METHOD_READ_DEBUG_LOG -> {
					try {
						val runtime = call.argument<String>(ARG_RUNTIME)
						result.success(AndroidVpnRuntimeManager.readDebugLog(applicationContext, runtime))
					} catch (t: Throwable) {
						result.error("READ_DEBUG_LOG_FAILED", t.message, null)
					}
				}
				METHOD_CLEAR_DEBUG_LOG -> {
					try {
						val runtime = call.argument<String>(ARG_RUNTIME)
						AndroidVpnRuntimeManager.clearDebugLog(applicationContext, runtime)
						result.success(null)
					} catch (t: Throwable) {
						result.error("CLEAR_DEBUG_LOG_FAILED", t.message, null)
					}
				}
				METHOD_LAST_ERROR -> {
					try {
						result.success(AndroidVpnRuntimeManager.lastStartupError(applicationContext))
					} catch (t: Throwable) {
						result.error("LAST_ERROR_FAILED", t.message, null)
					}
				}
				METHOD_TRAFFIC_STATS -> {
					try {
						val stats = com.neuravpn.app.vpn.XrayVpnService.readTrafficStats(applicationContext)
						if (stats != null && stats.size >= 2) {
							result.success(mapOf("tx" to stats[0], "rx" to stats[1]))
						} else {
							result.success(null)
						}
					} catch (t: Throwable) {
						result.error("TRAFFIC_STATS_FAILED", t.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}

		launchChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAUNCH_CHANNEL)
		launchChannel?.setMethodCallHandler { call, result ->
			when (call.method) {
				METHOD_GET_INITIAL_LAUNCH_URI -> {
					result.success(pendingLaunchUri)
					pendingLaunchUri = null
				}
				else -> result.notImplemented()
			}
		}

		// Cold start deep-link: store it until Flutter requests it.
		handleLaunchIntent(intent, deliverToFlutter = false)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		// App already running: deliver link immediately.
		handleLaunchIntent(intent, deliverToFlutter = true)
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

	private fun handleLaunchIntent(intent: Intent?, deliverToFlutter: Boolean) {
		val launchUri = extractLaunchUri(intent) ?: return
		if (deliverToFlutter && launchChannel != null) {
			launchChannel?.invokeMethod(METHOD_HANDLE_LAUNCH_URI, launchUri)
		} else {
			pendingLaunchUri = launchUri
		}
	}

	private fun extractLaunchUri(intent: Intent?): String? {
		if (intent?.action != Intent.ACTION_VIEW) {
			return null
		}
		val data = intent.data ?: return null
		val scheme = data.scheme?.lowercase() ?: return null
		when (scheme) {
			"neuravpn", "vless" -> return data.toString()
			"http", "https" -> {
				val host = data.host?.lowercase() ?: return null
				val path = data.encodedPath ?: return null
				if (host == "asort97.github.io" && path.startsWith("/neuravpn-site")) {
					return data.toString()
				}
				return null
			}
			else -> return null
		}
	}

	companion object {
		private const val CHANNEL = "happycat.vpn/native"
		private const val LAUNCH_CHANNEL = "neuravpn/android_launch"
		private const val METHOD_PREPARE = "prepareVpn"
		private const val METHOD_START = "startVpn"
		private const val METHOD_STOP = "stopVpn"
		private const val METHOD_STATUS = "getVpnStatus"
		private const val METHOD_READ_DEBUG_LOG = "getNativeVpnDebugLog"
		private const val METHOD_CLEAR_DEBUG_LOG = "clearNativeVpnDebugLog"
		private const val METHOD_LAST_ERROR = "getLastStartupError"
		private const val METHOD_TRAFFIC_STATS = "getTrafficStats"
		private const val METHOD_GET_INITIAL_LAUNCH_URI = "getInitialLaunchUri"
		private const val METHOD_HANDLE_LAUNCH_URI = "handleLaunchUri"
		private const val ARG_CONFIG = "config"
		private const val ARG_RUNTIME = "runtime"
		private const val ARG_EXECUTABLE_PATH = "executablePath"
		private const val ARG_INCLUDE_PACKAGES = "includePackages"
		private const val ARG_EXCLUDE_PACKAGES = "excludePackages"
		private const val REQUEST_PREPARE_VPN = 1001
	}
}
