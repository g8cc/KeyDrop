import Foundation
import CryptoKit
import CommonCrypto

/// 账本迁移(Phase 1):端到端加密的导出/导入文件。
/// 格式 = JSON 信封(formatVersion)内嵌 base64(AES-256-GCM combined 密文),
/// 口令经 PBKDF2-SHA256(60 万轮)派生密钥。载荷内含 schemaVersion ——
/// 信封与载荷双层版本化:信封变更是加密方式变更(formatVersion 递增),
/// 字段变更是载荷变更(schemaVersion 递增),导入端拒绝比自己新的 schema。
///
/// 设计取舍(见 docs/import-pipeline.md §数据迁移):只同步账本,不同步产物 ——
/// 账本是源,产物(cc-switch/CPA/DSH/Grok)在新机器由 Core.replayArtifacts 重放。

public struct LedgerEnvelope: Codable {
    var format: String          // "keydrop-export"
    var formatVersion: Int      // 信封格式版本(加密方式变更时递增)
    var kdf: String             // "PBKDF2-SHA256"
    var iterations: Int
    var salt: String            // base64
    var combined: String        // base64(nonce+ciphertext+tag)
}

public struct LedgerPayload: Codable {
    public var schemaVersion: Int      // 账本载荷版本(字段变更时递增)
    public var exportedAt: TimeInterval
    public var appVersion: String
    public var entries: [HistoryEntry]
    public var switches: SwitchSnapshot?

    public init(schemaVersion: Int, exportedAt: TimeInterval, appVersion: String,
                entries: [HistoryEntry], switches: SwitchSnapshot?) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.entries = entries
        self.switches = switches
    }

    public struct SwitchSnapshot: Codable {
        public var useCC: Bool
        public var useGrok: Bool
        public var useCPA: Bool
        public var useDSH: Bool
        public var cpaResident: Bool

        public init(useCC: Bool, useGrok: Bool, useCPA: Bool, useDSH: Bool, cpaResident: Bool) {
            self.useCC = useCC; self.useGrok = useGrok; self.useCPA = useCPA
            self.useDSH = useDSH; self.cpaResident = cpaResident
        }
    }
}

public enum LedgerTransferError: LocalizedError {
    case badPassphrase
    case badEnvelope(String)
    case schemaTooNew(Int)

    public var errorDescription: String? {
        switch self {
        case .badPassphrase:
            return "口令至少 8 位"
        case .badEnvelope(let s):
            return s
        case .schemaTooNew(let v):
            return "导出文件的 schema 版本(v\(v))比本机新,请先升级本机 KeyDrop 再导入"
        }
    }
}

public enum LedgerCrypto {
    public static let magic = "keydrop-export"
    public static let currentSchemaVersion = 1
    public static let iterations = 600_000
    static let marker = " …[已截断]… "

    public static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var out = Data(repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let status = out.withUnsafeMutableBytes { optr in
            salt.withUnsafeBytes { sptr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase, pw.count,
                    sptr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    optr.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 派生失败")
        return SymmetricKey(data: out)
    }

    /// 加密账本载荷 → 导出文件字节(JSON 信封)。口令不足 8 位拒绝。
    public static func seal(_ payload: Data, passphrase: String) throws -> Data {
        guard passphrase.count >= 8 else { throw LedgerTransferError.badPassphrase }
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let box = try AES.GCM.seal(payload, using: key)
        guard let combined = box.combined else {
            throw LedgerTransferError.badEnvelope("加密失败: 无法生成密文")
        }
        let env = LedgerEnvelope(
            format: magic, formatVersion: 1,
            kdf: "PBKDF2-SHA256", iterations: iterations,
            salt: salt.base64EncodedString(),
            combined: combined.base64EncodedString()
        )
        return try JSONEncoder().encode(env)
    }

    /// 解密导出文件 → 载荷字节。口令错误/文件损坏统一报"口令错误或文件已损坏"
    /// (不区分二者,避免向试探者泄露信息)。
    public static func open(_ fileData: Data, passphrase: String) throws -> Data {
        let env: LedgerEnvelope
        do {
            env = try JSONDecoder().decode(LedgerEnvelope.self, from: fileData)
        } catch {
            throw LedgerTransferError.badEnvelope("不是有效的 KeyDrop 导出文件")
        }
        guard env.format == magic, env.formatVersion == 1,
              env.kdf == "PBKDF2-SHA256",
              let salt = Data(base64Encoded: env.salt),
              let combined = Data(base64Encoded: env.combined)
        else {
            throw LedgerTransferError.badEnvelope("不是有效的 KeyDrop 导出文件")
        }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw LedgerTransferError.badEnvelope("解密失败: 口令错误或文件已损坏")
        }
    }
}
