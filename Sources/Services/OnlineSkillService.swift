import Foundation
import CoreLocation

/// 联网技能服务集合：搜索、图片生成、语音合成、定位
/// 这些能力仅在联网模式下使用，通过 Edge Function / 第三方接口调用
final class OnlineSkillService {
    static let shared = OnlineSkillService()
    private let session = URLSession.shared
    private init() {}

    // MARK: - 百度 AI 搜索
    func search(query: String) async throws -> [SearchResultItem] {
        // 通过 Supabase Edge Function 代理调用百度搜索，保护密钥
        let urlStr = (ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? "")
        guard !urlStr.isEmpty else { return [] }
        guard let url = URL(string: "\(urlStr)/functions/v1/baidu-search") else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        if let items = try? JSONDecoder().decode([SearchResultItem].self, from: data) {
            return items
        }
        return []
    }

    // MARK: - AI 图片生成（可灵 / GPT-Image）
    func generateImage(prompt: String) async throws -> String {
        let urlStr = (ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? "")
        guard !urlStr.isEmpty else { throw ChatError.requestFailed }
        guard let url = URL(string: "\(urlStr)/functions/v1/image-generate") else { throw ChatError.requestFailed }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw ChatError.requestFailed }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageUrl = obj["url"] as? String {
            return imageUrl
        }
        throw ChatError.requestFailed
    }

    // MARK: - MiniMax 语音合成
    func synthesizeSpeech(text: String) async throws -> String {
        let urlStr = (ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? "")
        guard !urlStr.isEmpty else { throw ChatError.requestFailed }
        guard let url = URL(string: "\(urlStr)/functions/v1/minimax-tts") else { throw ChatError.requestFailed }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw ChatError.requestFailed }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let audioURL = obj["audio_url"] as? String {
            return audioURL
        }
        throw ChatError.requestFailed
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