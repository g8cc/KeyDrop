import Foundation

/// 同步 HTTP 数据任务的统一封装:锁保护的共享结果 + 超时后取消任务并回收回调。
///
/// 全项目原先有 ~10 处手写的 `semaphore + dataTask` 模式,普遍存在同一类缺陷:
///   1. `sem.wait` 超时后任务未 cancel,残留在后台跑完(白耗连接);
///   2. 超时后主线程读共享变量(status/body/data),后台回调稍后仍在写 —— 数据竞争;
///   3. 部分实现连 cancel 都没有(fetchSubscriptionProxies)。
/// 新增网络调用请一律走这里,不要重开手写模式。
enum NetSync {

    struct Outcome {
        let data: Data?
        let response: URLResponse?
        let error: Error?
        /// 是否为等待超时后的强制取消(cancelled 或无响应都归入)
        var timedOut: Bool { error is URLError && (error as? URLError)?.code == .cancelled }
    }

    static func run(session: URLSession, request: URLRequest, timeout: TimeInterval) -> Outcome {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var data: Data?
        var response: URLResponse?
        var error: Error?

        let task = session.dataTask(with: request) { d, r, e in
            lock.lock()
            data = d; response = r; error = e
            lock.unlock()
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            // cancel 后 URLSession 保证 completion 仍会被调用一次(带 cancelled error),
            // 这里同步等它到达,彻底关闭「回调悬空晚写」的窗口
            task.cancel()
            _ = sem.wait(timeout: .now() + 5)
        }
        lock.lock(); defer { lock.unlock() }
        return Outcome(data: data, response: response, error: error)
    }

    static func run(session: URLSession, url: URL, timeout: TimeInterval) -> Outcome {
        run(session: session, request: URLRequest(url: url), timeout: timeout)
    }

    static func statusCode(_ o: Outcome) -> Int {
        (o.response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
