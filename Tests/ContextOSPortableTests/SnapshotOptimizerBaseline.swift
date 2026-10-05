// Captured from the unchanged macOS IndexStore-backed optimizer at ce795e7.
// Selection order, scores and budgets are exact; reason membership is canonicalized.
enum SnapshotOptimizerBaseline {
    static let json = #"""
    [
      {
        "case" : "english-import-chain",
        "context_score" : 100,
        "estimated_tokens" : 1002,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "‘login’ → symbol login"
            ],
            "score" : 7.2400000000000002
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 2.8999999999999999
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 1.1599999999999999
          }
        ],
        "query" : "fix login",
        "terms" : [
          "login"
        ],
        "token_budget" : 8000
      },
      {
        "case" : "tight-budget",
        "context_score" : 78,
        "estimated_tokens" : 334,
        "excluded" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 2.8999999999999999
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 1.1599999999999999
          }
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "‘login’ → symbol login"
            ],
            "score" : 7.2400000000000002
          }
        ],
        "query" : "login",
        "terms" : [
          "login"
        ],
        "token_budget" : 400
      },
      {
        "case" : "zero-budget",
        "context_score" : 0,
        "estimated_tokens" : 0,
        "excluded" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "‘login’ → symbol login"
            ],
            "score" : 7.2400000000000002
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 2.8999999999999999
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 1.1599999999999999
          }
        ],
        "included" : [
    
        ],
        "query" : "login",
        "terms" : [
          "login"
        ],
        "token_budget" : 0
      },
      {
        "case" : "korean-symbol",
        "context_score" : 100,
        "estimated_tokens" : 200,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 200,
            "language" : "swift",
            "path" : "src\/로그인.swift",
            "reasons" : [
              "‘로그인’ → symbol 로그인"
            ],
            "score" : 7.2400000000000002
          }
        ],
        "query" : "로그인",
        "terms" : [
          "로그인"
        ],
        "token_budget" : 8000
      },
      {
        "case" : "refined-korean-query",
        "context_score" : 100,
        "estimated_tokens" : 1002,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "‘login’ → symbol login"
            ],
            "score" : 7.2400000000000002
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 2.8999999999999999
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/login.py"
            ],
            "score" : 1.1599999999999999
          }
        ],
        "query" : "로그인 확인",
        "terms" : [
          "login"
        ],
        "token_budget" : 8000
      },
      {
        "case" : "stable-ties",
        "context_score" : 96,
        "estimated_tokens" : 200,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 100,
            "language" : "python",
            "path" : "src\/a.py",
            "reasons" : [
              "‘target’ → symbol target"
            ],
            "score" : 4.4900000000000002
          },
          {
            "estimated_tokens" : 100,
            "language" : "python",
            "path" : "src\/b.py",
            "reasons" : [
              "‘target’ → symbol target"
            ],
            "score" : 4.4900000000000002
          }
        ],
        "query" : "target",
        "terms" : [
          "target"
        ],
        "token_budget" : 8000
      },
      {
        "case" : "git-only",
        "context_score" : 84,
        "estimated_tokens" : 1336,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/billing.py",
            "reasons" : [
              "git: 커밋 안 된 변경"
            ],
            "score" : 3
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/database.py",
            "reasons" : [
              "git: 최근 수정됨"
            ],
            "score" : 1.5
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/database.py"
            ],
            "score" : 0.59999999999999998
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/database.py"
            ],
            "score" : 0.23999999999999999
          }
        ],
        "query" : "",
        "terms" : [
    
        ],
        "token_budget" : 8000
      },
      {
        "case" : "explicit-file",
        "context_score" : 71,
        "estimated_tokens" : 334,
        "excluded" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/jwt.py"
            ],
            "score" : 2
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/database.py",
            "reasons" : [
              "linked via src\/jwt.py"
            ],
            "score" : 2
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "linked via src\/jwt.py"
            ],
            "score" : 0.80000000000000004
          }
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "requested file src\/jwt.py"
            ],
            "score" : 5
          }
        ],
        "query" : "src\/jwt.py 설명",
        "terms" : [
          "설명"
        ],
        "token_budget" : 400
      },
      {
        "case" : "multiple-seeds",
        "context_score" : 100,
        "estimated_tokens" : 1336,
        "excluded" : [
    
        ],
        "included" : [
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/database.py",
            "reasons" : [
              "linked via src\/jwt.py",
              "‘connect’ → symbol connect"
            ],
            "score" : 10.130000000000001
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/jwt.py",
            "reasons" : [
              "linked via src\/database.py",
              "‘encode’ → symbol encode"
            ],
            "score" : 10.130000000000001
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/auth.py",
            "reasons" : [
              "linked via src\/database.py",
              "linked via src\/jwt.py"
            ],
            "score" : 4.0499999999999998
          },
          {
            "estimated_tokens" : 334,
            "language" : "python",
            "path" : "src\/login.py",
            "reasons" : [
              "linked via src\/jwt.py"
            ],
            "score" : 1.1599999999999999
          }
        ],
        "query" : "encode connect",
        "terms" : [
          "encode",
          "connect"
        ],
        "token_budget" : 8000
      },
      {
        "case" : "no-match",
        "context_score" : 0,
        "estimated_tokens" : 0,
        "excluded" : [
    
        ],
        "included" : [
    
        ],
        "query" : "wombat",
        "terms" : [
          "wombat"
        ],
        "token_budget" : 8000
      }
    ]
    """#
}
