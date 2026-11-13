package com.neuravpn.app

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * iOS-grade haptics for the `neuravpn/haptics` channel (same calls as the
 * iOS Runner: impact{style}, selection, notification{type}).
 *
 * Android 11+ phones with a good actuator get short crisp VibrationEffect
 * compositions; older devices fall back to predefined effects, then to
 * View.performHapticFeedback. The system "touch feedback" setting is honored.
 */
class NativeHaptics(private val activity: Activity) {

	private data class Tap(val primitive: Int, val scale: Float, val delayMs: Int = 0)

	private val vibrator: Vibrator? = run {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
			activity.getSystemService(VibratorManager::class.java)?.defaultVibrator
		} else {
			@Suppress("DEPRECATION")
			activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
		}
	}?.takeIf { it.hasVibrator() }

	fun register(messenger: BinaryMessenger) {
		MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
			val kind = when (call.method) {
				"selection" -> "selection"
				"impact" -> call.argument<String>("style") ?: "medium"
				"notification" -> call.argument<String>("type") ?: "success"
				else -> {
					result.notImplemented()
					return@setMethodCallHandler
				}
			}
			runCatching { play(kind) }
			result.success(null)
		}
	}

	private fun play(kind: String) {
		if (!touchFeedbackEnabled()) return
		val vibrator = vibrator
		if (vibrator == null) {
			playViewFeedback(kind)
			return
		}
		val effect = composition(vibrator, kind) ?: predefined(kind)
		if (effect == null) {
			playViewFeedback(kind)
			return
		}
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
			vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
		} else {
			@Suppress("DEPRECATION")
			vibrator.vibrate(
				effect,
				AudioAttributes.Builder()
					.setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
					.setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
					.build(),
			)
		}
	}

	/** Mirrors UIImpactFeedbackGenerator / UINotificationFeedbackGenerator. */
	private fun composition(vibrator: Vibrator, kind: String): VibrationEffect? {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
		val click = VibrationEffect.Composition.PRIMITIVE_CLICK
		val tick = VibrationEffect.Composition.PRIMITIVE_TICK
		val soft = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
			VibrationEffect.Composition.PRIMITIVE_LOW_TICK
		} else {
			tick
		}
		val taps = when (kind) {
			"selection" -> listOf(Tap(tick, 0.55f))
			"light" -> listOf(Tap(click, 0.45f))
			"soft" -> listOf(Tap(soft, 1.0f))
			"medium" -> listOf(Tap(click, 0.7f))
			"rigid" -> listOf(Tap(click, 0.85f))
			"heavy" -> listOf(Tap(click, 1.0f))
			"success" -> listOf(Tap(click, 0.5f), Tap(click, 1.0f, 90))
			"warning" -> listOf(Tap(click, 1.0f), Tap(click, 0.5f, 130))
			"error" -> listOf(Tap(click, 0.8f), Tap(click, 0.8f, 70), Tap(click, 1.0f, 70))
			else -> return null
		}
		val primitives = taps.map { it.primitive }.distinct().toIntArray()
		if (!vibrator.areAllPrimitivesSupported(*primitives)) return null
		val composition = VibrationEffect.startComposition()
		taps.forEach { composition.addPrimitive(it.primitive, it.scale, it.delayMs) }
		return composition.compose()
	}

	private fun predefined(kind: String): VibrationEffect? {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
		return VibrationEffect.createPredefined(
			when (kind) {
				"selection", "light", "soft" -> VibrationEffect.EFFECT_TICK
				"medium", "rigid" -> VibrationEffect.EFFECT_CLICK
				"success", "warning" -> VibrationEffect.EFFECT_DOUBLE_CLICK
				else -> VibrationEffect.EFFECT_HEAVY_CLICK
			},
		)
	}

	private fun playViewFeedback(kind: String) {
		val view = activity.window?.decorView ?: return
		@Suppress("DEPRECATION")
		val constant = when (kind) {
			"selection", "light", "soft" -> HapticFeedbackConstants.CLOCK_TICK
			"medium", "rigid", "success" -> HapticFeedbackConstants.VIRTUAL_KEY
			else -> HapticFeedbackConstants.LONG_PRESS
		}
		view.performHapticFeedback(constant)
	}

	private fun touchFeedbackEnabled(): Boolean {
		// Android 13+ applies the touch-feedback setting to USAGE_TOUCH itself.
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return true
		@Suppress("DEPRECATION")
		return Settings.System.getInt(
			activity.contentResolver,
			Settings.System.HAPTIC_FEEDBACK_ENABLED,
			1,
		) != 0
	}

	companion object {
		const val CHANNEL = "neuravpn/haptics"
	}
}
