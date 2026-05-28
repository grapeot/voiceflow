import Foundation

actor RealtimeWebSocketSender {
    private let task: URLSessionWebSocketTask
    private var pendingSend: Task<Void, Error>?

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let previous = pendingSend
        let current = Task {
            if let previous {
                try await previous.value
            }
            try await task.send(message)
        }
        pendingSend = current
        try await current.value
    }

    func flush() async throws {
        try await pendingSend?.value
    }
}
