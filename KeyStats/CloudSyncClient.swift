import Foundation

final class CloudSyncClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func register(baseURL: URL, username: String, password: String) async throws -> CloudAuthResponse {
        try await authRequest(baseURL: baseURL, path: "auth/register", username: username, password: password)
    }

    func login(baseURL: URL, username: String, password: String) async throws -> CloudAuthResponse {
        try await authRequest(baseURL: baseURL, path: "auth/login", username: username, password: password)
    }

    func listDevices(baseURL: URL, token: String) async throws -> [CloudDevice] {
        let response: CloudDevicesResponse = try await request(
            baseURL: baseURL,
            path: "devices",
            method: "GET",
            token: token
        )
        return response.devices
    }

    func registerDevice(baseURL: URL, token: String, requestBody: CloudRegisterDeviceRequest) async throws -> CloudDevice {
        try await self.request(
            baseURL: baseURL,
            path: "devices",
            method: "POST",
            token: token,
            body: requestBody
        )
    }

    func upsertStats(baseURL: URL, token: String, requestBody: CloudUpsertStatsRequest) async throws {
        let _: CloudUpsertStatsResponse = try await request(
            baseURL: baseURL,
            path: "sync/stats",
            method: "PUT",
            token: token,
            body: requestBody
        )
    }

    func bulkUpsertStats(baseURL: URL, token: String, requestBody: CloudBulkUpsertStatsRequest) async throws {
        let _: CloudBulkUpsertStatsResponse = try await request(
            baseURL: baseURL,
            path: "sync/stats/bulk",
            method: "POST",
            token: token,
            body: requestBody
        )
    }

    func listStats(baseURL: URL, token: String, from: String?, to: String?, deviceId: String?) async throws -> [CloudStatsRecord] {
        var queryItems: [URLQueryItem] = []
        if let from { queryItems.append(URLQueryItem(name: "from", value: from)) }
        if let to { queryItems.append(URLQueryItem(name: "to", value: to)) }
        if let deviceId { queryItems.append(URLQueryItem(name: "device_id", value: deviceId)) }

        let response: CloudStatsListResponse = try await request(
            baseURL: baseURL,
            path: "sync/stats",
            method: "GET",
            token: token,
            queryItems: queryItems
        )
        return response.records
    }

    private func authRequest(baseURL: URL, path: String, username: String, password: String) async throws -> CloudAuthResponse {
        try await request(
            baseURL: baseURL,
            path: path,
            method: "POST",
            body: CloudAuthRequest(username: username, password: password)
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        token: String? = nil,
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws -> Response {
        let url = apiURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func request<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        token: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let url = apiURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    private func apiURL(baseURL: URL, path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.path
        if basePath.hasSuffix("/") {
            basePath = String(basePath.dropLast())
        }
        components.path = "\(basePath)/api/v1/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url ?? baseURL
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudSyncError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }

        if (200...299).contains(http.statusCode) {
            if data.isEmpty {
                if let value = "{}".data(using: .utf8) {
                    if let decoded = try? decoder.decode(Response.self, from: value) {
                        return decoded
                    }
                }
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                #if DEBUG
                NSLog("[CloudSyncClient] decode failed for %@: %@", request.url?.absoluteString ?? "?", error.localizedDescription)
                #endif
                throw CloudSyncError.invalidResponse
            }
        }

        if let apiError = try? decoder.decode(CloudAPIErrorResponse.self, from: data) {
            throw CloudSyncError.serverError(apiError.error)
        }
        throw CloudSyncError.serverError("HTTP \(http.statusCode)")
    }
}
