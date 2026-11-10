import Foundation

enum ClementineError: LocalizedError {
    case cannotRead(URL)
    case cannotWrite(URL)
    case unsupported(String)
    case helperFailed(String)
    case noOutput
    case partial([String])

    var errorDescription: String? {
        switch self {
        case .cannotRead(let url): return "Could not read \(url.lastPathComponent)."
        case .cannotWrite(let url): return "Could not write \(url.lastPathComponent)."
        case .unsupported(let what): return what
        case .helperFailed(let msg): return msg
        case .noOutput: return "The operation produced no output."
        case .partial(let msgs): return msgs.joined(separator: "\n")
        }
    }
}
