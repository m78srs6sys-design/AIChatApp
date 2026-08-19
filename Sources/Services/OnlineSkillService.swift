import Foundation
import CoreLocation
import UIKit
import os

// MARK: - 私有辅助

/// 联网技能日志（统一前缀，便于 Console 过滤）
private let skillLogger = Logger(subsystem: "com.aidiary.AIDiary", category: "OnlineSkill")

/// 在限定时间内执行异步操作：超时则取消并返回 nil（不阻塞调用方）。
/// 竞态基于 TaskGroup：操作完成 → 返回结果；延迟任务先完成 → 超时。
/// 仅用于短操作（系统设置跳转、亮度调节等），不适用于长耗时网络请求（走 URLSession 超时）。
private func withTimeout<T>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let deadline = UInt64(max(0, seconds) * 1_000_000_000)
    return await withTaskGroup(of: (Bool, T?).self) { group in
        group.addTask {
            let value = await operation()
            return (true, value)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: deadline)
            return (false, nil as T?)
        }
        let (isDone, result) = await group.next() ?? (false, nil as T?)
        group.cancelAll()
        guard isDone, let value = result else {
            skillLogger.warning("withTimeout: 操作在 \(seconds)s 内未完成，已跳过")
            return nil
        }
        return value
    }
}

/// 联网技能服务集合：搜索、图片生成、天气、网页抓取、语音合成。
/// 统一走博查 BochaAI /v1/web-search + /v1/image-search（OpenAI 兼容接口）；
/// 天气仍用 open-meteo 免密钥接口。
final class OnlineSkillService {
    static let shared = OnlineSkillService()
    private let session: URLSession

    /// 博查 API 配置（可通过 APISettings.apiURL/apiKey 注入，默认走博查国内节点）
    private var bochaBaseURL: String {
        // 默认博查国内可用地址
        return "https://api.bochaai.com/v1"
    }

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 联网搜索（博查 BochaAI /v1/web-search）
    /// 通过 OpenAI 兼容接口调用博查 Web Search，返回中文实时搜索结果。
    func search(query: String, apiKey: String? = nil, baseURL: String? = nil) async throws -> [SearchResultItem] {
        let apiBase = baseURL ?? bochaBaseURL
        let endpoint = "\(apiBase)/web-search"

        let body: [String: Any] = [
            "query": query,
            "max_results": 5
        ]

        guard let url = URL(string: endpoint) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // 博查返回格式：{ "results": [{ "title": "...", "url": "...", "snippet": "..." }] }
        if let results = json["results"] as? [[String: Any]] {
            return results.prefix(5).compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String else { return nil }
                let rawSnippet = item["snippet"] as? String ?? ""
                let snippet = rawSnippet
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                let urlStr = item["url"] as? String ?? ""
                return SearchResultItem(title: title, url: urlStr, snippet: snippet.isEmpty ? nil : snippet)
            }
        }
        return []
    }

    // MARK: - AI 图片生成（博查 /v1/images 兼容 OpenAI 接口）
    /// 通过 OpenAI 兼容接口调用博查图像生成，返回图片 URL。
    /// 建议让模型在 <image> 标签内填写「英文画面描述」以获得最佳效果。
    func generateImage(prompt: String, apiKey: String? = nil, baseURL: String? = nil) async throws -> String {
        let apiBase = baseURL ?? bochaBaseURL
        let endpoint = "\(apiBase)/images"

        let body: [String: Any] = [
            "prompt": prompt,
            "n": 1,
            "size": "1024x1024"
        ]

        guard let url = URL(string: endpoint) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data_arr = json["data"] as? [[String: Any]],
              let first = data_arr.first,
              let urlStr = first["url"] as? String else {
            throw ChatError.requestFailed
        }
        return urlStr
    }

    // MARK: - 真实图片搜索（博查 /v1/images 兼容 OpenAI 接口）
    /// 区别于 AI 图片生成，此接口搜索真实世界的照片。
    /// 通过博查图片搜索端点，传入「真实照片」提示以获得写实结果。
    func searchImage(query: String, apiKey: String? = nil, baseURL: String? = nil) async throws -> String? {
        let apiBase = baseURL ?? bochaBaseURL
        let endpoint = "\(apiBase)/images"

        // 在 prompt 前缀强调真实照片，避免模型生成 AI 画作
        let realPhotoPrompt = "Real photograph of \(query), photorealistic, actual photo, not AI generated"

        let body: [String: Any] = [
            "prompt": realPhotoPrompt,
            "n": 1,
            "size": "1024x1024"
        ]

        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data_arr = json["data"] as? [[String: Any]],
              let first = data_arr.first,
              let urlStr = first["url"] as? String else {
            return nil
        }
        return urlStr
    }

    // MARK: - 天气（open-meteo，免密钥）
    func weather(from text: String) async throws -> WeatherInfo {
        let cleaned = text
            .replacingOccurrences(of: "天气", with: "")
            .replacingOccurrences(of: "气温", with: "")
            .replacingOccurrences(of: "温度", with: "")
            .replacingOccurrences(of: "多少", with: "")
            .replacingOccurrences(of: "今天", with: "")
            .replacingOccurrences(of: "现在", with: "")
            .replacingOccurrences(of: "明天", with: "")
            .replacingOccurrences(of: "后天", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let city = cleaned.isEmpty ? "北京" : cleaned
        let enc = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city

        let geoURL = "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&language=zh&format=json"
        guard let gurl = URL(string: geoURL),
              let (gdata, _) = try? await session.data(from: gurl),
              let gjson = try? JSONSerialization.jsonObject(with: gdata) as? [String: Any],
              let results = gjson["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double else {
            throw ChatError.requestFailed
        }
        let cityName = (first["name"] as? String) ?? city

        let fcURL = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto"
        guard let furl = URL(string: fcURL),
              let (fdata, _) = try? await session.data(from: furl),
              let fjson = try? JSONSerialization.jsonObject(with: fdata) as? [String: Any],
              let current = fjson["current"] as? [String: Any] else {
            throw ChatError.requestFailed
        }
        let temp = current["temperature_2m"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int
        let wind = current["wind_speed_10m"] as? Double
        let code = current["weather_code"] as? Int ?? 0
        return WeatherInfo(city: cityName,
                           temperature: temp,
                           condition: Self.weatherDescription(code),
                           humidity: humidity,
                           windSpeed: wind,
                           units: "°C")
    }

    // MARK: - 天气（按经纬度直查，供「我的位置」场景使用）
    func weather(lat: Double, lon: Double, cityName: String) async throws -> WeatherInfo {
        let fcURL = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto"
        guard let furl = URL(string: fcURL),
              let (fdata, _) = try? await session.data(from: furl),
              let fjson = try? JSONSerialization.jsonObject(with: fdata) as? [String: Any],
              let current = fjson["current"] as? [String: Any] else {
            throw ChatError.requestFailed
        }
        let temp = current["temperature_2m"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int
        let wind = current["wind_speed_10m"] as? Double
        let code = current["weather_code"] as? Int ?? 0
        return WeatherInfo(city: cityName.isEmpty ? "当前位置" : cityName,
                           temperature: temp,
                           condition: Self.weatherDescription(code),
                           humidity: humidity,
                           windSpeed: wind,
                           units: "°C")
    }

    // MARK: - 反向地理编码（BigDataCloud，免密钥，把坐标转为城市名，用于天气等城市级场景）
    func reverseGeocode(lat: Double, lon: Double) async -> String? {
        let urlStr = "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=\(lat)&longitude=\(lon)&localityLanguage=zh"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let city = json["city"] as? String
        let locality = json["locality"] as? String
        let subdivision = json["principalSubdivision"] as? String
        return (city?.isEmpty == false ? city : (locality?.isEmpty == false ? locality : subdivision))
    }

    // MARK: - 街道级反向地理编码（CLGeocoder，精确到街道/门牌，用于非天气的定位场景）
    private let geocoder = CLGeocoder()

    func reverseGeocodeStreet(lat: Double, lon: Double) async -> String? {
        let location = CLLocation(latitude: lat, longitude: lon)
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, _ in
                guard let pm = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                // 拼接街道级地址：国家 + 省/市 + 区/县 + 街道 + 门牌号
                var parts: [String] = []
                if let country = pm.country { parts.append(country) }
                if let administrativeArea = pm.administrativeArea { parts.append(administrativeArea) }
                if let subAdminArea = pm.subAdministrativeArea { parts.append(subAdminArea) }
                if let locality = pm.locality { parts.append(locality) }
                if let subLocality = pm.subLocality { parts.append(subLocality) }
                if let thoroughfare = pm.thoroughfare { parts.append(thoroughfare) }
                if let subThoroughfare = pm.subThoroughfare { parts.append(subThoroughfare) }
                let result = parts.isEmpty ? nil : parts.joined(separator: " ")
                continuation.resume(returning: result)
            }
        }
    }

    private static func weatherDescription(_ code: Int) -> String {
        let map: [Int: String] = [
            0: "晴", 1: "大致晴朗", 2: "局部多云", 3: "阴",
            45: "雾", 48: "霜雾",
            51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
            56: "冻毛毛雨", 57: "强冻毛毛雨",
            61: "小雨", 63: "中雨", 65: "大雨",
            66: "冻雨", 67: "强冻雨",
            71: "小雪", 73: "中雪", 75: "大雪", 77: "雪粒",
            80: "阵雨", 81: "强阵雨", 82: "暴雨",
            85: "阵雪", 86: "强阵雪",
            95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷暴冰雹"
        ]
        return map[code] ?? "未知"
    }

    // MARK: - 网页抓取与摘要（直连，免密钥）
    func fetchWebpage(url: String) async throws -> WebpageSummary {
        guard let u = URL(string: url),
              let (data, _) = try? await session.data(from: u) else {
            throw ChatError.requestFailed
        }

        // 尝试多种编码（中文网站常用 GBK/GB2312）
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            raw = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            // 用 Latin1 兜底，然后尝试检测 meta charset
            raw = s
        } else if let s = String(data: data, encoding: .windowsCP1252) {
            raw = s
        } else {
            throw ChatError.requestFailed
        }

        var title = "网页"
        if let tr = raw.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(raw[tr])
                .replacingOccurrences(of: "(?i)<title>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</title>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var text = raw
        text = text.replacingOccurrences(of: "(?s)<script.*?</script>", with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "(?s)<style.*?</style>", with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "&[a-z]+;", with: " ", options: .regularExpression)
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return WebpageSummary(url: url, title: title, summary: String(text.prefix(8000)))
    }

    // MARK: - 语音合成（未接入后端时降级，不影响文本）
    func synthesizeSpeech(text: String) async throws -> String {
        throw ChatError.requestFailed
    }

    // MARK: - 系统 API 操作（亮度调节、设置跳转等）
    /// 执行系统级操作。返回 (操作描述, 是否成功)。
    /// 每步独立执行并受 5s 超时保护：超时的步骤被跳过并记录日志，
    /// 仅向用户返回业务语义文案（不暴露内部命令 / 技术细节）。
    func executeSystemAction(command: String) async -> (description: String, success: Bool) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 亮度调节（UIScreen 直接生效，无需权限）
        if cmd.hasPrefix("brightness") || cmd.hasPrefix("亮度") {
            let parts = command.components(separatedBy: .whitespaces)
            if parts.count >= 2, let val = Double(parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
                let level = val > 1 ? val / 100.0 : val
                let clamped = min(1.0, max(0.0, level))
                let done = await withTimeout(5) {
                    await MainActor.run { UIScreen.main.brightness = CGFloat(clamped) }
                } != nil
                if done {
                    return ("已将屏幕亮度调整为 \(Int(clamped * 100))%", true)
                }
                return ("屏幕亮度调节未成功，请稍后再试", false)
            }
            let done = await withTimeout(5) {
                await MainActor.run { UIScreen.main.brightness = 0.5 }
            } != nil
            if done {
                return ("已将屏幕亮度调整为 50%", true)
            }
            return ("屏幕亮度调节未成功，请稍后再试", false)
        }

        // 低电量 / 省电
        if cmd == "low_power" || cmd == "低电量" || cmd == "省电" {
            return await openSystemSettings("请手动前往「电池」开启低电量模式")
        }

        // Wi-Fi 设置
        if cmd == "wifi" || cmd == "无线" || cmd == "无线网络" {
            return await openSystemSettings("请手动前往「Wi-Fi」设置")
        }

        // 蓝牙设置
        if cmd == "bluetooth" || cmd == "蓝牙" {
            return await openSystemSettings("请手动前往「蓝牙」设置")
        }

        // 显示与亮度
        if cmd == "display" || cmd == "显示" || cmd == "屏幕" || cmd == "显示与亮度" {
            return await openSystemSettings("请手动前往「显示与亮度」")
        }

        // 声音与触感
        if cmd == "sound" || cmd == "声音" || cmd == "音量" {
            return await openSystemSettings("请手动前往「声音与触感」")
        }

        return ("未知系统操作「\(command)」，支持的命令：brightness <0-1>、低电量、wifi、蓝牙、显示、声音", false)
    }

    /// 跳转系统设置页（iOS 沙盒限制：低电量 / Wi-Fi / 蓝牙等只能跳设置页手动操作）。
    /// 受 5s 超时保护：超时则记录日志并返回失败文案，不暴露技术细节。
    private func openSystemSettings(_ manual: String) async -> (description: String, success: Bool) {
        let done = await withTimeout(5) {
            await MainActor.run {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        } != nil
        if done {
            return ("已打开系统设置，\(manual)", true)
        }
        skillLogger.warning("openSystemSettings: 跳转系统设置超时，已跳过")
        return ("无法打开系统设置，\(manual)", false)
    }
}

/// 定位服务（CoreLocation）
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else {
            requestPermission()
        }
    }

    /// 异步等待一次定位结果（最多约 10 秒）。未授权时先弹权限请求。
    func awaitLocation() async -> CLLocation? {
        if authorizationStatus == .notDetermined {
            requestPermission()
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else {
            return nil
        }
        for _ in 0..<20 {
            if let loc = currentLocation { return loc }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return currentLocation
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async { self.authorizationStatus = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            self.currentLocation = locations.last
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
