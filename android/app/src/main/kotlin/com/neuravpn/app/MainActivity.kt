package com.neuravpn.app

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.VpnService
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.InstallStatus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.neuravpn.app.vpn.AndroidVpnRuntimeManager
import com.neuravpn.app.vpn.XrayVpnService
import com.neuravpn.app.vpn.ProfileProbeChannel

class MainActivity : FlutterActivity() {

	private var pendingPrepareResult: MethodChannel.Result? = null
	private var pendingLaunchUri: String? = null
	private var launchChannel: MethodChannel? = null
	private lateinit var appUpdateManager: AppUpdateManager
	private var playUpdateChannel: EventChannel? = null
	private var playUpdateEvents: EventChannel.EventSink? = null
	private var playInstallStatus = InstallStatus.UNKNOWN
	private val playInstallListener = InstallStateUpdatedListener { state ->
		playInstallStatus = state.installStatus()
		playUpdateEvents?.success(playInstallStatus)
	}
	private var profileProbeChannel: ProfileProbeChannel? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		profileProbeChannel?.close()
		profileProbeChannel = ProfileProbeChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
		appUpdateManager = AppUpdateManagerFactory.create(applicationContext)
		playUpdateChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "neuravpn/play_update")
		playUpdateChannel?.setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
				playUpdateEvents = events
				appUpdateManager.registerListener(playInstallListener)
			}
			override fun onCancel(arguments: Any?) {
				appUpdateManager.unregisterListener(playInstallListener)
				playUpdateEvents = null
			}
		})
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
						val routingMode = call.argument<String>(ARG_ROUTING_MODE)
						if (config.isNullOrBlank()) {
							result.error("INVALID_CONFIG", "Config payload required", null)
						} else {
							AndroidVpnRuntimeManager.start(
								context = applicationContext,
								runtimeId = runtime,
								config = config,
								executablePath = executablePath,
								includePackages = includePackages,
								excludePackages = excludePackages,
								routingMode = routingMode,
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
						val snapshot = AndroidVpnRuntimeManager.status(applicationContext)
						val stats = XrayVpnService.readTrafficStats(applicationContext)
						result.success(snapshot.toMap(
							tx = stats?.getOrNull(0),
							rx = stats?.getOrNull(1),
						))
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
				METHOD_REFRESH_NETWORK -> {
					try {
						XrayVpnService.refreshNetwork(applicationContext)
						result.success(null)
					} catch (t: Throwable) {
						result.error("REFRESH_NETWORK_FAILED", t.message, null)
					}
				}
				METHOD_OPEN_VPN_SETTINGS -> {
					try {
						startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
						result.success(true)
					} catch (t: Throwable) {
						result.error("OPEN_VPN_SETTINGS_FAILED", t.message, null)
					}
				}
				"openAppSettings" -> {
					try {
						startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
							Uri.parse("package:$packageName")))
						result.success(true)
					} catch (t: Throwable) {
						result.error("OPEN_APP_SETTINGS_FAILED", "Cannot open app settings", null)
					}
				}
				METHOD_CHECK_PLAY_UPDATE -> checkPlayUpdate(result)
				METHOD_START_PLAY_UPDATE -> startPlayUpdate(result)
				METHOD_COMPLETE_PLAY_UPDATE -> {
					appUpdateManager.completeUpdate()
						.addOnSuccessListener { result.success(true) }
						.addOnFailureListener { error ->
							result.error(
								"PLAY_UPDATE_UNAVAILABLE",
								playUpdateErrorMessage(error),
								null,
							)
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

	override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
		appUpdateManager.unregisterListener(playInstallListener)
		playUpdateChannel?.setStreamHandler(null)
		playUpdateChannel = null
		playUpdateEvents = null
		profileProbeChannel?.close()
		profileProbeChannel = null
		super.cleanUpFlutterEngine(flutterEngine)
	}

	private fun checkPlayUpdate(result: MethodChannel.Result) {
		if (!isPlayInstallation()) {
			result.error("PLAY_UPDATE_UNAVAILABLE", "This installation is not eligible for Play updates.", null)
			return
		}
		appUpdateManager.appUpdateInfo
			.addOnSuccessListener { info ->
				playInstallStatus = info.installStatus()
				result.success(
					mapOf(
						"available" to
							(info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE),
						"developerTriggeredUpdateInProgress" to
							(info.updateAvailability() ==
								UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS),
						"availableVersionCode" to info.availableVersionCode(),
						"installStatus" to info.installStatus(),
						"flexibleAllowed" to info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE),
						"immediateAllowed" to info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE),
						"source" to "google_play",
					),
				)
			}
			.addOnFailureListener { error ->
				result.error(
					"PLAY_UPDATE_UNAVAILABLE",
					playUpdateErrorMessage(error),
					null,
				)
			}
	}

	private fun startPlayUpdate(result: MethodChannel.Result) {
		if (!isPlayInstallation()) {
			result.error("PLAY_UPDATE_UNAVAILABLE", "This installation is not eligible for Play updates.", null)
			return
		}
		appUpdateManager.appUpdateInfo
			.addOnSuccessListener { info ->
				val canStart =
					info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
						info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)
				if (!canStart) {
					result.error(
						"PLAY_UPDATE_NOT_AVAILABLE",
						"Google Play does not currently offer an update for this installation.",
						null,
					)
					return@addOnSuccessListener
				}
				try {
					@Suppress("DEPRECATION")
					val started = appUpdateManager.startUpdateFlowForResult(
						info,
						AppUpdateType.FLEXIBLE,
						this,
						REQUEST_PLAY_UPDATE,
					)
					result.success(started)
				} catch (error: Throwable) {
					result.error("PLAY_UPDATE_START_FAILED", playUpdateErrorMessage(error), null)
				}
			}
			.addOnFailureListener { error ->
				result.error(
					"PLAY_UPDATE_UNAVAILABLE",
					playUpdateErrorMessage(error),
					null,
				)
			}
	}

	private fun playUpdateErrorMessage(error: Throwable): String {
		val detail = error.message?.trim().orEmpty()
		return if (detail.isEmpty()) {
			"In-app updates are available only for an app installed by Google Play."
		} else {
			"In-app updates are available only for an app installed by Google Play: $detail"
		}
	}

	private fun isPlayInstallation(): Boolean {
		if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) return false
		return runCatching {
			val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
				packageManager.getInstallSourceInfo(packageName).installingPackageName
			} else {
				@Suppress("DEPRECATION")
				packageManager.getInstallerPackageName(packageName)
			}
			installer == "com.android.vending"
		}.getOrDefault(false)
	}

	override fun onResume() {
		super.onResume()
		// Reconcile only an already accepted download; do not check for new
		// releases every time the user returns from another app or a VPN dialog.
		if (::appUpdateManager.isInitialized && playInstallStatus in listOf(
			InstallStatus.PENDING, InstallStatus.DOWNLOADING, InstallStatus.INSTALLING,
		)) {
			appUpdateManager.appUpdateInfo.addOnSuccessListener { info ->
				playInstallStatus = info.installStatus()
				playUpdateEvents?.success(playInstallStatus)
			}
		}
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
			"neuravpn", "vless", "hysteria2", "hy2" -> return data.toString()
			"http", "https" -> {
				val host = data.host?.lowercase() ?: return null
				val path = data.encodedPath ?: return null
				if (host == "asort97.github.io" && path.startsWith("/neuravpn-site")) {
					return data.toString()
				}
				if (
					host == "webhook.staticdeliverycdn.com" &&
					path.startsWith("/merged-sub/")
				) {
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
		private const val METHOD_REFRESH_NETWORK = "refreshNetwork"
		private const val METHOD_OPEN_VPN_SETTINGS = "openVpnSettings"
		private const val METHOD_CHECK_PLAY_UPDATE = "checkPlayUpdate"
		private const val METHOD_START_PLAY_UPDATE = "startPlayUpdate"
		private const val METHOD_COMPLETE_PLAY_UPDATE = "completePlayUpdate"
		private const val METHOD_GET_INITIAL_LAUNCH_URI = "getInitialLaunchUri"
		private const val METHOD_HANDLE_LAUNCH_URI = "handleLaunchUri"
		private const val ARG_CONFIG = "config"
		private const val ARG_RUNTIME = "runtime"
		private const val ARG_EXECUTABLE_PATH = "executablePath"
		private const val ARG_INCLUDE_PACKAGES = "includePackages"
		private const val ARG_EXCLUDE_PACKAGES = "excludePackages"
		private const val ARG_ROUTING_MODE = "routingMode"
		private const val REQUEST_PREPARE_VPN = 1001
		private const val REQUEST_PLAY_UPDATE = 1002
	}
}
