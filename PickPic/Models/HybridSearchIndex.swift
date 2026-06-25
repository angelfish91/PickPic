import Foundation
import SQLite3

struct HybridSearchDocument: Sendable {
    let assetID: String
    let modifiedAt: TimeInterval?
    let visualText: String
    let ocrText: String
    let peopleText: String
    let contextText: String

    var isEmpty: Bool {
        [visualText, ocrText, peopleText, contextText]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct HybridSearchMatch: Sendable {
    let assetID: String
    let score: Float
}

actor HybridSearchIndex {
    static let shared = HybridSearchIndex()

    private let database: HybridSearchIndexDatabase?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("PickPic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = HybridSearchIndexDatabase(
            url: directory.appendingPathComponent("hybrid-search-index-v1.sqlite")
        )
    }

    func upsert(_ documents: [HybridSearchDocument]) {
        let searchableDocuments = documents.filter { !$0.isEmpty }
        guard !searchableDocuments.isEmpty else { return }
        database?.upsert(searchableDocuments)
    }

    func delete(assetIDs: Set<String>) {
        database?.delete(assetIDs: Array(assetIDs))
    }

    func reconcile(validAssetIDs: Set<String>) {
        database?.reconcile(validAssetIDs: validAssetIDs)
    }

    func clear() {
        database?.clear()
    }

    func flush() {
        database?.commit()
    }

    func search(_ query: String, limit: Int = 120) -> [HybridSearchMatch] {
        let ftsQuery = Self.ftsQuery(for: query)
        guard !ftsQuery.isEmpty else { return [] }
        return database?.search(ftsQuery, limit: limit) ?? []
    }

    private static func ftsQuery(for query: String) -> String {
        let normalized = query
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let splitTerms = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let expandedTerms = splitTerms + queryExpansionTerms(for: normalized)
        let uniqueTerms = Array(Set(expandedTerms))
            .filter { $0.count >= 2 }
            .sorted()

        return uniqueTerms
            .compactMap(ftsPrefixTerm)
            .joined(separator: " OR ")
    }

    private static func ftsPrefixTerm(_ term: String) -> String? {
        let disallowedCharacters = CharacterSet(charactersIn: "\"'*:^{}()[]")
            .union(.whitespacesAndNewlines)
        let safe = term.unicodeScalars
            .filter { !disallowedCharacters.contains($0) }
            .map(String.init)
            .joined()
        guard !safe.isEmpty else { return nil }
        return "\(safe)*"
    }

    private static func queryExpansionTerms(for query: String) -> [String] {
        let expansions: [(keys: [String], terms: [String])] = [
            (["人", "人物", "人脸", "合照", "自拍", "朋友", "家人"], [
                "person", "people", "face", "portrait", "selfie", "group", "人", "人脸", "合照", "自拍"
            ]),
            (["小孩", "孩子", "儿童", "宝宝", "婴儿"], [
                "child", "kid", "baby", "toddler", "小孩", "孩子", "宝宝"
            ]),
            (["笑", "微笑", "开心"], ["smile", "happy", "微笑", "开心"]),
            (["狗", "猫", "宠物", "动物"], ["dog", "cat", "pet", "animal", "狗", "猫", "宠物"]),
            (["吃饭", "餐厅", "食物", "美食", "咖啡", "蛋糕", "饮料"], [
                "food", "meal", "restaurant", "dish", "coffee", "cake", "drink", "餐厅", "食物", "咖啡", "蛋糕"
            ]),
            (["海", "海边", "沙滩", "湖", "水"], ["beach", "ocean", "sea", "coast", "lake", "water", "海边", "沙滩"]),
            (["山", "森林", "花", "树", "天空", "云", "自然"], [
                "mountain", "forest", "flower", "tree", "sky", "cloud", "nature", "山", "森林", "天空"
            ]),
            (["城市", "街道", "夜景", "建筑", "车"], [
                "city", "street", "night", "building", "car", "traffic", "城市", "街道", "夜景"
            ]),
            (["文字", "菜单", "海报", "截图", "文档", "二维码", "条码"], [
                "text", "menu", "poster", "screenshot", "document", "barcode", "qr", "文字", "菜单", "文档", "二维码"
            ]),
            (["红", "红色"], ["red", "红色"]),
            (["蓝", "蓝色"], ["blue", "蓝色"]),
            (["绿", "绿色"], ["green", "绿色"]),
            (["白", "白色"], ["white", "白色"]),
            (["黑", "黑色"], ["black", "黑色"])
        ]

        var terms: [String] = []
        for expansion in expansions where expansion.keys.contains(where: { query.contains($0) }) {
            terms.append(contentsOf: expansion.terms)
        }
        return terms
    }
}

private final class HybridSearchIndexDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private var transactionOpen = false

    init?(url: URL) {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }

        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA temp_store=MEMORY")
        execute("""
            CREATE TABLE IF NOT EXISTS hybrid_documents (
                asset_id TEXT PRIMARY KEY,
                modified_at REAL
            ) WITHOUT ROWID
            """)
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS hybrid_documents_fts USING fts5(
                asset_id UNINDEXED,
                visual,
                ocr,
                people,
                context,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
    }

    deinit {
        commit()
        if let handle {
            sqlite3_close(handle)
        }
    }

    func upsert(_ documents: [HybridSearchDocument]) {
        guard !documents.isEmpty else { return }
        beginTransactionIfNeeded()

        for document in documents {
            upsertMetadata(document)
            deleteFTS(assetID: document.assetID)
            insertFTS(document)
        }
    }

    func delete(assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        beginTransactionIfNeeded()
        for assetID in assetIDs {
            deleteMetadata(assetID: assetID)
            deleteFTS(assetID: assetID)
        }
    }

    func reconcile(validAssetIDs: Set<String>) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT asset_id FROM hybrid_documents",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        var staleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetCString = sqlite3_column_text(statement, 0) else { continue }
            let assetID = String(cString: assetCString)
            if !validAssetIDs.contains(assetID) {
                staleIDs.append(assetID)
            }
        }
        delete(assetIDs: staleIDs)
    }

    func search(_ query: String, limit: Int) -> [HybridSearchMatch] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            """
            SELECT asset_id, bm25(hybrid_documents_fts, 3.5, 7.0, 4.0, 1.2) AS rank
            FROM hybrid_documents_fts
            WHERE hybrid_documents_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return []
        }

        sqlite3_bind_text(statement, 1, query, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var matches: [HybridSearchMatch] = []
        matches.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetCString = sqlite3_column_text(statement, 0) else { continue }
            let assetID = String(cString: assetCString)
            let positionScore = max(0.05, 1 - Float(matches.count) / Float(max(limit, 1)))
            matches.append(HybridSearchMatch(assetID: assetID, score: positionScore))
        }
        return matches
    }

    func commit() {
        guard transactionOpen else { return }
        execute("COMMIT")
        transactionOpen = false
    }

    func clear() {
        commit()
        execute("DELETE FROM hybrid_documents")
        execute("DELETE FROM hybrid_documents_fts")
        execute("VACUUM")
    }

    private func upsertMetadata(_ document: HybridSearchDocument) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            """
            INSERT INTO hybrid_documents(asset_id, modified_at)
            VALUES(?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                modified_at = excluded.modified_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, document.assetID, -1, Self.transient)
        if let modifiedAt = document.modifiedAt {
            sqlite3_bind_double(statement, 2, modifiedAt)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_step(statement)
    }

    private func deleteMetadata(assetID: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "DELETE FROM hybrid_documents WHERE asset_id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, assetID, -1, Self.transient)
        sqlite3_step(statement)
    }

    private func insertFTS(_ document: HybridSearchDocument) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            """
            INSERT INTO hybrid_documents_fts(asset_id, visual, ocr, people, context)
            VALUES(?, ?, ?, ?, ?)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, document.assetID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, document.visualText, -1, Self.transient)
        sqlite3_bind_text(statement, 3, document.ocrText, -1, Self.transient)
        sqlite3_bind_text(statement, 4, document.peopleText, -1, Self.transient)
        sqlite3_bind_text(statement, 5, document.contextText, -1, Self.transient)
        sqlite3_step(statement)
    }

    private func deleteFTS(assetID: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "DELETE FROM hybrid_documents_fts WHERE asset_id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, assetID, -1, Self.transient)
        sqlite3_step(statement)
    }

    private func beginTransactionIfNeeded() {
        guard !transactionOpen else { return }
        execute("BEGIN IMMEDIATE")
        transactionOpen = true
    }

    private func execute(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }
}
