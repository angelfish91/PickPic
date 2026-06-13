import Foundation

struct SigLIPTokenizer {
    private struct TokenizerFile: Decodable {
        let model: Model

        struct Model: Decodable {
            let unk_id: Int
            let vocab: [VocabularyEntry]
        }
    }

    private struct VocabularyEntry: Decodable {
        let token: String
        let score: Float

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            token = try container.decode(String.self)
            score = try container.decode(Float.self)
        }
    }

    private struct Piece {
        let id: Int
        let characters: [Character]
        let score: Float
    }

    let eosTokenID = 1
    private let unknownTokenID: Int
    private let piecesByFirstCharacter: [Character: [Piece]]

    init(contentsOf url: URL) throws {
        let file = try JSONDecoder().decode(TokenizerFile.self, from: Data(contentsOf: url))
        unknownTokenID = file.model.unk_id

        var grouped: [Character: [Piece]] = [:]
        for (id, entry) in file.model.vocab.enumerated() {
            let characters = Array(entry.token)
            guard let first = characters.first, !entry.token.hasPrefix("<") else { continue }
            grouped[first, default: []].append(Piece(id: id, characters: characters, score: entry.score))
        }
        piecesByFirstCharacter = grouped.mapValues { pieces in
            pieces.sorted { $0.characters.count > $1.characters.count }
        }
    }

    func encode(_ text: String) -> [Int] {
        let characters = Array(normalize(text))
        guard !characters.isEmpty else { return [] }

        var bestScores = Array(repeating: -Float.infinity, count: characters.count + 1)
        var previousPositions = Array(repeating: -1, count: characters.count + 1)
        var tokenIDs = Array(repeating: unknownTokenID, count: characters.count + 1)
        bestScores[0] = 0

        for position in characters.indices where bestScores[position].isFinite {
            var foundPiece = false
            for piece in piecesByFirstCharacter[characters[position], default: []] {
                let end = position + piece.characters.count
                guard end <= characters.count,
                      Array(characters[position..<end]) == piece.characters
                else {
                    continue
                }

                foundPiece = true
                let score = bestScores[position] + piece.score
                if score > bestScores[end] {
                    bestScores[end] = score
                    previousPositions[end] = position
                    tokenIDs[end] = piece.id
                }
            }

            if !foundPiece, bestScores[position] - 100 > bestScores[position + 1] {
                bestScores[position + 1] = bestScores[position] - 100
                previousPositions[position + 1] = position
                tokenIDs[position + 1] = unknownTokenID
            }
        }

        var result: [Int] = []
        var position = characters.count
        while position > 0, previousPositions[position] >= 0 {
            result.append(tokenIDs[position])
            position = previousPositions[position]
        }
        return result.reversed()
    }

    private func normalize(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping.lowercased()
        let removablePunctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-.:;=?@[\\]^_`{|}~")
        let withoutPunctuation = compatible.unicodeScalars
            .filter { !removablePunctuation.contains($0) }
            .map(String.init)
            .joined()
        let collapsedWhitespace = withoutPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsedWhitespace.isEmpty
            ? ""
            : "▁" + collapsedWhitespace.replacingOccurrences(of: " ", with: "▁")
    }
}
