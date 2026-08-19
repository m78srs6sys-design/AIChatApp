import Foundation
import CoreLocation
import UIKit

/// 联网技能服务集合：搜索、图片生成、天气、网页抓取、语音合成。
/// 全部使用「免密钥」公开接口实现，无需配置任何后端服务：
///   - 搜索：维基百科 API
///   - 图片生成：Pollinations.ai
///   - 天气：open-meteo
///   - 网页抓取：直连目标 URL 并裁剪正文
final class OnlineSkillService {
    static let shared = OnlineSkillService()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 联网搜索（DuckDuckGo 免密钥 API，更可靠）
    func search(query: String) async throws -> [SearchResultItem] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        // 主搜索：DuckDuckGo Instant Answer API（免密钥，返回摘要 + 相关话题）
        let ddgUrl = "https://api.duckduckgo.com/?q=\(q)&format=json&no_html=1&skip_disambig=1"
        if let url = URL(string: ddgUrl),
           let (data, _) = try? await session.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var results: [SearchResultItem] = []
            // 1. 提取摘要（Abstract）
            if let abstract = json["Abstract"] as? String, !abstract.isEmpty,
               let source = json["AbstractSource"] as? String,
               let absUrl = json["AbstractURL"] as? String {
                results.append(SearchResultItem(
                    title: "\(source)摘要",
                    url: absUrl,
                    snippet: abstract))
            }
            // 2. 提取 RelatedTopics
            if let topics = json["RelatedTopics"] as? [[String: Any]] {
                for t in topics {
                    if let text = t["Text"] as? String, !text.isEmpty,
                       let url = t["FirstURL"] as? String {
                        results.append(SearchResultItem(title: text.components(separatedBy: " - ").first ?? text,
                                                        url: url,
                                                        snippet: text))
                    }
                    // 嵌套 Topics（某些分类下还有子话题）
                    if let subTopics = t["Topics"] as? [[String: Any]] {
                        for st in subTopics {
                            if let text = st["Text"] as? String, !text.isEmpty,
                               let url = st["FirstURL"] as? String {
                                results.append(SearchResultItem(title: text.components(separatedBy: " - ").first ?? text,
                                                                url: url,
                                                                snippet: text))
                            }
                        }
                    }
                    if results.count >= 5 { break }
                }
            }
            if !results.isEmpty { return results }
        }
        // 降级：维基百科搜索（当 DuckDuckGo 无结果时）
        let wpUrl = "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(q)&format=json&srlimit=4&prop=snippet"
        guard let url = URL(string: wpUrl) else { return [] }
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let searchArr = queryObj["search"] as? [[String: Any]] else { return [] }
        return searchArr.compactMap { d -> SearchResultItem? in
            guard let title = d["title"] as? String else { return nil }
            let raw = d["snippet"] as? String ?? ""
            let snippet = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return SearchResultItem(title: title,
                                    url: "https://zh.wikipedia.org/wiki/\(enc)",
                                    snippet: snippet.isEmpty ? nil : snippet)
        }
    }

    // MARK: - AI 图片生成（Pollinations，免密钥，直出图片 URL）
    /// 使用 flux-pro 模型 + enhance 自动增强提示词（大幅提升「贴合度」）。
    /// 建议让模型在 <image> 标签内填写「英文画面描述」以获得最佳效果。
    func generateImage(prompt: String) async throws -> String {
        let p = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prompt
        // 使用多个种子重试，取最佳效果；使用 flux-pro 模型提升画质
        for _ in 0..<3 {
            let seed = Int.random(in: 1...1_000_000)
            let url = "https://image.pollinations.ai/prompt/\(p)?width=1024&height=1024&nologo=true&model=flux-pro&enhance=true&seed=\(seed)"
            guard URL(string: url) != nil else { throw ChatError.requestFailed }
            // 快速验证图片是否可访问（仅检查头信息）
            if let u = URL(string: url) {
                var req = URLRequest(url: u)
                req.httpMethod = "HEAD"
                req.timeoutInterval = 10
                if let (_, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   http.statusCode == 200 {
                    return url
                }
            }
        }
        // 兜底：返回最后一次的 URL
        let seed = Int.random(in: 1...1_000_000)
        return "https://image.pollinations.ai/prompt/\(p)?width=1024&height=1024&nologo=true&model=flux-pro&enhance=true&seed=\(seed)"
    }

    // MARK: - 真实图片搜索（Wikipedia 免密钥，搜索实物/地点照片）
    /// 区别于 AI 图片生成，此接口返回真实世界的照片。
    /// 通过 Wikipedia 搜索条目并获取其代表性图片。
    func searchImage(query: String) async throws -> String? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        // 1. 搜索 Wikipedia 条目
        let searchUrl = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(q)&format=json&srlimit=1"
        guard let url = URL(string: searchUrl) else { return nil }
        let (data, _) = try await session.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let searchArr = queryObj["search"] as? [[String: Any]],
              let first = searchArr.first,
              let title = first["title"] as? String else { return nil }
        // 2. 获取条目的代表性图片
        let encTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let imageUrl = "https://en.wikipedia.org/w/api.php?action=query&titles=\(encTitle)&prop=pageimages&format=json&pithumbsize=500"
        guard let imgUrl = URL(string: imageUrl),
              let (imgData, _) = try? await session.data(from: imgUrl),
              let imgJson = try? JSONSerialization.jsonObject(with: imgData) as? [String: Any],
              let query = imgJson["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else { return nil }
        for (_, pageVal) in pages {
            if let page = pageVal as? [String: Any],
               let thumbnail = page["thumbnail"] as? [String: Any],
               let source = thumbnail["source"] as? String {
                return source
            }
        }
        return nil
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
              let (data, _) = try? await session.data(from: u),
              let raw = String(data: data, encoding: .utf8) else {
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
        return WebpageSummary(url: url, title: title, summary: String(text.prefix(4000)))
    }

    // MARK: - 语音合成（未接入后端时降级，不影响文本）
    func synthesizeSpeech(text: String) async throws -> String {
        throw ChatError.requestFailed
    }

    // MARK: - 系统 API 操作（亮度调节、设置跳转等）
    /// 执行系统级操作。返回 (操作描述, 是否成功)
    func executeSystemAction(command: String) -> (description: String, success: Bool) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if cmd == "low_power" || cmd == "低电量" || cmd == "省电" {
            // 打开设置 → 电池页面（iOS 无法直接编程开启低电量模式）
            let urlStr = UIApplication.openSettingsURLString + "BATTERY_USAGE"
            if let url = URL(string: urlStr), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return ("已打开「设置 → 电池」，请手动开启低电量模式", true)
            }
            // 降级：打开设置首页
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
                return ("已打开系统设置，请手动前往「电池」开启低电量模式", true)
            }
            return ("无法打开设置", false)
        }

        if cmd.hasPrefix("brightness") || cmd.hasPrefix("亮度") {
            // 解析亮度值：brightness 0.5 或 亮度 50%
            let parts = command.components(separatedBy: .whitespaces)
            if parts.count >= 2, let val = Double(parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
                let level = val > 1 ? val / 100.0 : val
                let clamped = min(1.0, max(0.0, level))
                UIScreen.main.brightness = CGFloat(clamped)
                return ("已将屏幕亮度调整为 \(Int(clamped * 100))%", true)
            }
            // 默认调节到 50%
            UIScreen.main.brightness = 0.5
            return ("已将屏幕亮度调整为 50%", true)
        }

        if cmd == "wifi" || cmd == "无线" || cmd == "无线网络" {
            if let url = URL(string: "App-Prefs:root=WIFI"),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return ("已打开「设置 → Wi-Fi」", true)
            }
            return ("无法打开 Wi-Fi 设置", false)
        }

        if cmd == "bluetooth" || cmd == "蓝牙" {
            if let url = URL(string: "App-Prefs:root=Bluetooth"),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return ("已打开「设置 → 蓝牙」", true)
            }
            return ("无法打开蓝牙设置", false)
        }

        if cmd == "display" || cmd == "显示" || cmd == "屏幕" || cmd == "显示与亮度" {
            if let url = URL(string: "App-Prefs:root=DISPLAY"),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return ("已打开「设置 → 显示与亮度」", true)
            }
            return ("无法打开显示设置", false)
        }

        if cmd == "sound" || cmd == "声音" || cmd == "音量" {
            if let url = URL(string: "App-Prefs:root=Sounds"),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return ("已打开「设置 → 声音与触感」", true)
            }
            return ("无法打开声音设置", false)
        }

        return ("未知系统操作「\(command)」，支持的命令：brightness <0-1>、低电量、wifi、蓝牙、显示、声音", false)
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
