import Foundation
import KeyDropCore

/// stdio JSON-RPC MCP server:暴露 generate_image 工具,供 claude/codex 的 agent 调用
enum MCPImageServer {

    static func run() -> Int32 {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = Data()

        while true {
            // 读一帧:Content-Length 头 + JSON body
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                let chunk = stdin.readData(ofLength: 4096)
                if chunk.isEmpty {
                    if buffer.isEmpty { return 0 }
                    return 0
                }
                buffer.append(chunk)
                continue
            }
            let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            guard let lenLine = header.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let len = Int(lenLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                buffer.removeSubrange(..<(headerEnd.upperBound))
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.count >= bodyStart + len else {
                let chunk = stdin.readData(ofLength: 4096)
                if chunk.isEmpty { return 0 }
                buffer.append(chunk)
                continue
            }
            let body = Data(buffer[bodyStart..<(bodyStart + len)])
            buffer.removeSubrange(..<(bodyStart + len))

            guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]

            var response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
            ]
            let result: [String: Any]?
            let errResp: [String: Any]?
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": msg["params"].flatMap { ($0 as? [String: Any])?["protocolVersion"] as? String } ?? "2024-11-05",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "keydrop-image", "version": Version.currentVersion()],
                ]
                errResp = nil
            case "notifications/initialized", "initialized":
                result = [:]
                errResp = nil
            case "ping":
                result = [:]
                errResp = nil
            case "tools/list":
                result = ["tools": [[
                    "name": "generate_image",
                    "description": "调用生图渠道生成一张图片并保存到本地,返回图片文件路径。prompt 用英文描述效果更佳。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "prompt": ["type": "string", "description": "图片内容描述(建议英文)"],
                            "model": ["type": "string", "description": "生图模型,缺省用渠道默认"],
                            "size": ["type": "string", "description": "尺寸,如 1024x1024"],
                        ],
                        "required": ["prompt"],
                    ],
                ]]]
                errResp = nil
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let args = params["arguments"] as? [String: Any] ?? [:]
                guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                    result = nil
                    errResp = ["code": -32602, "message": "缺少 prompt 参数"]
                    break
                }
                guard let channel = ImageChannelStore.load() else {
                    result = nil
                    errResp = ["code": -32001, "message": "未配置生图渠道,请先运行 keydrop image-add <key> <url>"]
                    break
                }
                let model = (args["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? channel.model
                let size = (args["size"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1024x1024"
                do {
                    let path = try ImageAPI.generate(
                        baseURL: channel.url, key: channel.key,
                        prompt: prompt, model: model, size: size
                    )
                    result = [
                        "content": [
                            ["type": "text", "text": "图片已保存: \(path)"],
                        ],
                        "isError": false,
                    ]
                    errResp = nil
                } catch {
                    result = [
                        "content": [
                            ["type": "text", "text": "生成失败: \(error.localizedDescription)"],
                        ],
                        "isError": true,
                    ]
                    errResp = nil
                }
            default:
                result = nil
                errResp = ["code": -32601, "message": "未知方法: \(method)"]
            }
            response["result"] = result ?? NSNull()
            response["error"] = errResp ?? NSNull()
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
            stdout.write(frame)
        }
    }
}