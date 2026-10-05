/// Supplied index data for pure ranking. Capturing files or reading storage is
/// the platform adapter's responsibility; this value performs no I/O.
public struct IndexSnapshot: Sendable {
    public let files: [IndexedFile]
    public let symbolsByFile: [Int64: [Symbol]]
    public let importsByFile: [Int64: [ImportEdge]]

    public init(files: [IndexedFile], symbolsByFile: [Int64: [Symbol]],
                importsByFile: [Int64: [ImportEdge]]) {
        self.files = files
        self.symbolsByFile = symbolsByFile
        self.importsByFile = importsByFile
    }
}
