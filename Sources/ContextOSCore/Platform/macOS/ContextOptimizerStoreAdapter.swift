extension ContextOptimizer {
    /// Keep the existing Mac API. Only this adapter depends on SQLite storage;
    /// ranking consumes the same value snapshot on every platform.
    public func selectContext(query: String, from store: IndexStore, tokenBudget: Int,
                              signals: GitSignals = .empty, overrideTerms: [String]? = nil) throws -> ContextSelection {
        let snapshot = IndexSnapshot(files: try store.allFiles(),
                                     symbolsByFile: try store.symbolsByFile(),
                                     importsByFile: try store.importsByFile())
        return selectContext(query: query, from: snapshot, tokenBudget: tokenBudget,
                             signals: signals, overrideTerms: overrideTerms)
    }
}
