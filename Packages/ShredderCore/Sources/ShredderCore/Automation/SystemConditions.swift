import CoreGraphics
import Foundation
import IOKit.ps

/// 電源・負荷・アイドル状態（仕様 19.2, 19.3）。
public struct SystemConditions: Sendable, Hashable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var thermalPressure: Bool
    /// 最後の入力からの秒数。
    public var idleSeconds: TimeInterval

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermalPressure: Bool = false, idleSeconds: TimeInterval = 0) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermalPressure = thermalPressure
        self.idleSeconds = idleSeconds
    }

    public static func current() -> SystemConditions {
        let thermal = ProcessInfo.processInfo.thermalState
        return SystemConditions(
            onBattery: isOnBattery(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalPressure: thermal == .serious || thermal == .critical,
            idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        )
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}

/// 省電力モードでの処理方針。
public struct PowerPolicy: Sendable, Hashable {
    /// 省電力制御（設定「バックグラウンド」）。
    public var powerSavingEnabled: Bool

    public init(powerSavingEnabled: Bool = true) {
        self.powerSavingEnabled = powerSavingEnabled
    }

    /// 自動処理そのものを止めるべきか（高温時は常に止める）。
    public func shouldPause(_ conditions: SystemConditions) -> Bool {
        conditions.thermalPressure || (powerSavingEnabled && conditions.lowPowerMode && conditions.onBattery)
    }

    /// 負荷の高い解析（内容抽出・言語モデル）を控えるべきか。
    public func limitsHeavyAnalysis(_ conditions: SystemConditions) -> Bool {
        powerSavingEnabled && (conditions.onBattery || conditions.lowPowerMode)
    }

    /// アイドル時スキャンを実行してよいか。
    public func allowsIdleScan(_ conditions: SystemConditions, idleThreshold: TimeInterval) -> Bool {
        !shouldPause(conditions) && !limitsHeavyAnalysis(conditions) && conditions.idleSeconds >= idleThreshold
    }
}
