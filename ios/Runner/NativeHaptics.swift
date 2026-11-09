import Flutter
import UIKit

final class NativeHaptics {
    private var channel: FlutterMethodChannel?
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    private let impacts: [String: UIImpactFeedbackGenerator] = [
        "light": UIImpactFeedbackGenerator(style: .light),
        "medium": UIImpactFeedbackGenerator(style: .medium),
        "heavy": UIImpactFeedbackGenerator(style: .heavy),
        "soft": UIImpactFeedbackGenerator(style: .soft),
        "rigid": UIImpactFeedbackGenerator(style: .rigid)
    ]

    func register(with messenger: FlutterBinaryMessenger) {
        impacts.values.forEach { $0.prepare() }
        selection.prepare()
        notification.prepare()
        let channel = FlutterMethodChannel(name: "neuravpn/haptics", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "impact":
                guard let style = args["style"] as? String, let generator = self.impacts[style] else {
                    result(FlutterError(code: "INVALID_STYLE", message: "Unknown impact style.", details: nil))
                    return
                }
                generator.prepare()
                if let intensity = args["intensity"] as? Double, intensity.isFinite {
                    generator.impactOccurred(intensity: CGFloat(min(1, max(0, intensity))))
                } else { generator.impactOccurred() }
                generator.prepare()
            case "selection":
                self.selection.prepare()
                self.selection.selectionChanged()
                self.selection.prepare()
            case "notification":
                let types: [String: UINotificationFeedbackGenerator.FeedbackType] = [
                    "success": .success, "warning": .warning, "error": .error
                ]
                guard let type = args["type"] as? String, let feedback = types[type] else {
                    result(FlutterError(code: "INVALID_TYPE", message: "Unknown notification type.", details: nil))
                    return
                }
                self.notification.prepare()
                self.notification.notificationOccurred(feedback)
                self.notification.prepare()
            default: result(FlutterMethodNotImplemented); return
            }
            result(nil)
        }
        self.channel = channel
    }
}
