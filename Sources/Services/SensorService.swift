import Foundation
import CoreMotion
import UIKit

/// 系统传感器服务：气压计（CMAltimeter）、计步器（CMPedometer）、电池、内存、存储。
/// 海拔（GPS 高度）与指南针（heading）由 CoreLocation 提供（见 LocationService / OnlineSkillService），
/// 此处提供其余可直接读取的传感器数据，供「系统操作」工具与设置页展示使用。
enum SensorService {

    /// 中文名映射（用于展示与 AI 提示词）
    static func displayName(for key: String) -> String {
        switch key {
        case "altitude": return "海拔"
        case "barometer": return "气压"
        case "heading": return "指南针"
        case "steps": return "步数"
        case "battery": return "电池"
        case "memory": return "内存"
        case "storage": return "存储"
        default: return key
        }
    }

    /// 方位角 → 中文方向（如 0°=北、90°=东）
    static func headingDirection(_ degrees: Double) -> String {
        let dirs = ["正北", "东北", "正东", "东南", "正南", "西南", "正西", "西北"]
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let idx = Int((normalized + 22.5) / 45) % 8
        return dirs[idx]
    }

    // MARK: - 气压计（CMAltimeter，无需额外授权）

    /// 一次性读取当前气压（hPa）。设备无气压计时返回 nil。
    /// CMAltimeter 的 pressure 单位为 kPa，1 kPa = 10 hPa。
    static func currentBarometer() async -> Double? {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            let altimeter = CMAltimeter()
            let queue = OperationQueue()
            queue.name = "com.aichat.barometer"
            queue.qualityOfService = .utility
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
                altimeter.stopRelativeAltitudeUpdates()
                if let data {
                    continuation.resume(returning: data.pressure.doubleValue * 10)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 计步器（CMPedometer，需「运动与健身」权限）

    /// 今日累计步数。无权限 / 设备不支持时返回 nil。
    static func stepsToday() async -> Int? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        return await withCheckedContinuation { continuation in
            CMPedometer().queryPedometerData(from: startOfDay, to: now) { data, _ in
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }

    // MARK: - 电池（UIDevice，无需授权）

    /// 当前电量（0~1）与状态描述。
    static func batteryInfo() -> (level: Double, state: String) {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel >= 0 ? Double(device.batteryLevel) : 0
        let state: String
        switch device.batteryState {
        case .unplugged: state = "使用中"
        case .charging: state = "充电中"
        case .full: state = "已充满"
        default: state = "未知"
        }
        return (level, state)
    }

    // MARK: - 内存与存储（无需授权）

    /// App 当前内存占用（MB）与设备总内存（GB）。
    static func memoryUsage() -> (appMB: Double, deviceTotalGB: Double) {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let appMB = kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        return (appMB, totalGB)
    }

    /// 设备剩余可用存储（GB，保留一位小数）。
    static func freeStorageGB() -> Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(free) / 1_073_741_824
    }

    // MARK: - 汇总

    /// 汇总所有可读取的传感器数据（供「所有传感器」命令与权限页展示）。
    /// - Parameters:
    ///   - altitude: 海拔（米，GPS 提供，可空）
    ///   - headingDegrees: 方位角（度，定位提供，可空）
    static func allSnapshot(altitude: Double?, headingDegrees: Double?) async -> [String: String] {
        var out: [String: String] = [:]
        if let altitude {
            out["altitude"] = String(format: "%.0f 米", altitude)
        }
        if let heading = headingDegrees {
            out["heading"] = String(format: "%.0f° · %@", heading, headingDirection(heading))
        }
        if let p = await currentBarometer() {
            out["barometer"] = String(format: "%.1f hPa", p)
        }
        if let s = await stepsToday() {
            out["steps"] = "\(s) 步"
        }
        let (level, state) = batteryInfo()
        out["battery"] = "\(Int(level * 100))%（\(state)）"
        let (appMB, totalGB) = memoryUsage()
        out["memory"] = String(format: "App 占用 %.0f MB / 设备共 %.1f GB", appMB, totalGB)
        if let free = freeStorageGB() {
            out["storage"] = String(format: "剩余 %.1f GB", free)
        }
        return out
    }
}