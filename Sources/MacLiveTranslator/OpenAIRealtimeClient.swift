import Foundation

@MainActor
final class OpenAIRealtimeClient: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isSessionReady = false
    @Published var status = "尚未連線"
    @Published var transcript = ""
    @Published var errorMessage: String?

    private var webSocket: URLSessionWebSocketTask?
    private var isSocketOpen = false
    private var isReceiveLoopRunning = false
    private var pendingControlMessages: [[String: Any]] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func connect(apiKey: String, targetLanguage: String) {
        disconnect()

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "請先輸入 OPENAI_API_KEY。"
            return
        }

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        components?.queryItems = [
            URLQueryItem(name: "model", value: "gpt-realtime")
        ]

        guard let url = components?.url else {
            errorMessage = "Realtime API URL 無效。"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocket = task
        isSocketOpen = false
        isReceiveLoopRunning = false
        status = "連線中..."
        task.resume()

        let instructions = """
        You are a live interpreter. Translate all incoming speech into \(targetLanguage). \
        Output only the translated text. Keep each response concise and natural. \
        Do not explain, summarize, or add commentary.
        """

        queueControlMessage([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ]
                ],
            ]
        ])
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        isSessionReady = false
        isSocketOpen = false
        isReceiveLoopRunning = false
        pendingControlMessages.removeAll()
        status = "尚未連線"
    }

    func sendAudio(_ data: Data) {
        guard isSocketOpen, isSessionReady else { return }
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    private func queueControlMessage(_ object: [String: Any]) {
        if isSocketOpen {
            sendJSON(object)
        } else {
            pendingControlMessages.append(object)
        }
    }

    private func flushPendingControlMessages() {
        let messages = pendingControlMessages
        pendingControlMessages.removeAll()
        messages.forEach(sendJSON)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard isSocketOpen,
              let webSocket,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard self?.isSocketOpen == true else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func receiveLoop() {
        guard isSocketOpen, let webSocket else { return }

        webSocket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.webSocket === webSocket else { return }

                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop()
                case .failure(let error):
                    guard self.isSocketOpen else { return }
                    self.isConnected = false
                    self.isSessionReady = false
                    self.isSocketOpen = false
                    self.isReceiveLoopRunning = false
                    self.status = "連線中斷"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }

        guard let text,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            isConnected = true
            status = "已連線，正在設定..."
        case "session.updated":
            isConnected = true
            isSessionReady = true
            status = "已連線，正在聽..."
        case "response.text.delta", "response.output_text.delta":
            appendDelta(object["delta"] as? String)
        case "response.audio_transcript.delta":
            appendDelta(object["delta"] as? String)
        case "response.done":
            transcript += "\n"
        case "error":
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                errorMessage = message
            } else {
                errorMessage = text
            }
        default:
            break
        }
    }

    private func appendDelta(_ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        transcript += delta
    }
}

extension OpenAIRealtimeClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            guard self.webSocket === webSocketTask else { return }
            self.isSocketOpen = true
            self.isConnected = true
            self.status = "已連線，正在設定..."
            self.flushPendingControlMessages()
            if !self.isReceiveLoopRunning {
                self.isReceiveLoopRunning = true
                self.receiveLoop()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            guard self.webSocket === webSocketTask else { return }
            self.isConnected = false
            self.isSessionReady = false
            self.isSocketOpen = false
            self.isReceiveLoopRunning = false
            if let reason, let text = String(data: reason, encoding: .utf8), !text.isEmpty {
                self.status = "連線已關閉：\(text)"
            } else {
                self.status = "連線已關閉"
            }
        }
    }
}
