import Foundation
import KeyDropCore

/// stdio JSON-RPC MCP server:暴露 generate_image 工具,供 claude/codex 的 agent 调用
enum MCPImageServer {

    static func run() -> Int32 {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = Data()

        while true {
            // 防 O(n²) 扫描与内存膨胀:长期收不到完整 header 的垃圾数据直接断开
            if buffer.count > 16 * 1024 * 1024 { return 1 }
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
            // split(separator:) 默认丢弃空段,"content-length:" 后为空时只剩 1 段,
            // 直接下标 [1] 会数组越界崩掉整个 MCP server —— 必须安全取段
            guard let lenLine = header.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let lenPart = lenLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first,
                  let len = Int(lenPart.trimmingCharacters(in: .whitespacesAndNewlines)),
                  len >= 0, len <= 8 * 1024 * 1024 else {
                // 多行 header 中间行带 \r,只 trim .whitespaces 会解析失败;
                // 负数/超大的 len 会构造非法 Range 崩溃,一律丢弃该 header 继续
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
            // notification(无 id)不需要也不能回包,回包会被部分客户端当成协议错误
            let id = msg["id"]
            guard id != nil else { continue }

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
                    errResp = ["code": -32001, "message": "未配置生图渠道,请先运行 keydrop image-add <key> <url>(有 CPA 时会自动聚合)"]
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
            // JSON-RPC 2.0:result 与 error 只能出现其一。旧实现两个键都写(其中一个为 NSNull),
            // 部分客户端用 `"error" in msg` 判断失败,会把成功响应(含 error:null)当错误处理。
            if let errResp {
                response["error"] = errResp
            } else {
                response["result"] = result ?? [:]
            }
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
            stdout.write(frame)
        }
    }
}