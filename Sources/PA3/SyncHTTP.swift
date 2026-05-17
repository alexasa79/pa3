import Foundation

struct SyncHTTPResult {
    let data: Data?
    let statusCode: Int
    let error: Error?
}

private final class SyncHTTPBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = SyncHTTPResult(data: nil, statusCode: 0, error: nil)

    func store(data: Data?, response: URLResponse?, error: Error?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        result = SyncHTTPResult(data: data, statusCode: status, error: error)
        lock.unlock()
    }

    func load() -> SyncHTTPResult {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

enum SyncHTTP {
    static func data(for request: URLRequest) -> SyncHTTPResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncHTTPBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.store(data: data, response: response, error: error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return box.load()
    }

    static func dataTask(for request: URLRequest) -> (task: URLSessionDataTask, wait: () -> SyncHTTPResult) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncHTTPBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.store(data: data, response: response, error: error)
            semaphore.signal()
        }
        let wait = {
            semaphore.wait()
            return box.load()
        }
        return (task, wait)
    }
}
