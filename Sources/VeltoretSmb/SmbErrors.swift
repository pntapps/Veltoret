import Foundation

/// A network share problem, worded for people (wrong password, server off, folder gone…). Its `message` is shown
/// as is. `underlying` keeps the technical cause for logs.
public struct SmbError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let message: String
    public let underlying: Error?
    public init(_ message: String, underlying: Error? = nil) { self.message = message; self.underlying = underlying }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The NT status codes Veltoret words for people. AMSMB2 (libsmb2) reports them as POSIX errors whose text holds
/// the status name ("… STATUS_LOGON_FAILURE"), which is how they're recognised.
public enum SmbStatus: String, Sendable, CaseIterable {
    case logonFailure = "STATUS_LOGON_FAILURE"
    case accountDisabled = "STATUS_ACCOUNT_DISABLED"
    case passwordExpired = "STATUS_PASSWORD_EXPIRED"
    case accessDenied = "STATUS_ACCESS_DENIED"
    case badNetworkName = "STATUS_BAD_NETWORK_NAME"
    case objectNameNotFound = "STATUS_OBJECT_NAME_NOT_FOUND"
    case objectPathNotFound = "STATUS_OBJECT_PATH_NOT_FOUND"
    case notSupported = "STATUS_NOT_SUPPORTED"
    case invalidSmb = "STATUS_INVALID_SMB"
    case ioTimeout = "STATUS_IO_TIMEOUT"
    case networkNameDeleted = "STATUS_NETWORK_NAME_DELETED"
    case userSessionDeleted = "STATUS_USER_SESSION_DELETED"
    case connectionDisconnected = "STATUS_CONNECTION_DISCONNECTED"
    case connectionReset = "STATUS_CONNECTION_RESET"
    case connectionAborted = "STATUS_CONNECTION_ABORTED"
    case objectNameCollision = "STATUS_OBJECT_NAME_COLLISION"

    /// The first known status name in a library error message.
    static func find(in text: String) -> SmbStatus? {
        var search = text[...]
        while let r = search.range(of: "STATUS_") {
            var end = r.upperBound
            while end < search.endIndex, search[end].isUppercase || search[end] == "_" || search[end].isNumber {
                end = search.index(after: end)
            }
            if let s = SmbStatus(rawValue: String(search[r.lowerBound..<end])) { return s }
            search = search[r.upperBound...]
        }
        return nil
    }
}

/// An SMB request the server answered with an error status.
public struct SmbStatusError: Error, CustomStringConvertible, Sendable {
    public let status: SmbStatus
    public let operation: String
    public init(_ status: SmbStatus, _ operation: String) { self.status = status; self.operation = operation }
    public var description: String { "\(operation) failed: \(status.rawValue)" }
}

/// The connection to the server is gone (closed, timed out, or the request got no answer).
public struct SmbTransportError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Socket-level problems found before SMB starts (the quick TCP probe, name lookup).
public enum SmbSocketError: Error, CustomStringConvertible, Sendable {
    case hostNotFound(String)
    case refused
    case timedOut
    case unreachable(Int32)

    public var description: String {
        switch self {
        case .hostNotFound(let h): return "Host not found: \(h)"
        case .refused: return "Connection refused"
        case .timedOut: return "Connect timed out"
        case .unreachable(let e): return "Network unreachable (\(e))"
        }
    }
}

public enum SmbErrors {
    public static let wrongLogin = "Wrong username or password"
    public static let accountDisabled = "This user account is disabled on the server"
    public static let couldntReach = "Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi."
    public static let unknownHost = "Couldn't find that server on your network. Check the address."
    public static let connectionLost = "The connection to the server was lost"
    public static let fallback = "Something went wrong talking to the server"
    public static let noGuests = "This server doesn't allow guests. Sign in with its username and password."

    /// A sentence for the user. Walks the cause chain (`SmbError.underlying`, `NSUnderlyingErrorKey`).
    /// Unknown errors keep their own message.
    public static func describe(_ e: Error) -> String {
        var cause: Error? = e
        var depth = 0
        while let c = cause, depth < 16 {
            if let text = sentence(for: c) { return text }
            cause = underlying(of: c)
            depth += 1
        }
        let own = message(of: e)
        return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : own
    }

    /// The sentence for one error (not its causes), or nil when it says nothing we can word.
    private static func sentence(for c: Error) -> String? {
        switch c {
        case let se as SmbError:
            return se.message
        case let s as SmbSocketError:
            if case .hostNotFound = s { return unknownHost }
            return couldntReach
        case let s as SmbStatusError:
            return statusText(s.status)
        case is SmbTransportError:
            return connectionLost
        default:
            break
        }
        let ns = c as NSError
        if ns.domain == NSPOSIXErrorDomain {
            let text = ns.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
            if let status = SmbStatus.find(in: text), let s = statusText(status) { return s }
            return posixText(Int32(ns.code))
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return unknownHost
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet: return couldntReach
            case NSURLErrorNetworkConnectionLost: return connectionLost
            default: return nil
            }
        }
        return nil
    }

    static func statusText(_ status: SmbStatus) -> String? {
        switch status {
        case .logonFailure: return wrongLogin
        case .accountDisabled: return accountDisabled
        case .passwordExpired: return "This user's password has expired on the server"
        case .accessDenied: return "This user isn't allowed to open that folder"
        case .badNetworkName: return "The server has no shared folder with that name"
        case .objectNameNotFound, .objectPathNotFound: return "That folder or file isn't on the server any more"
        case .notSupported: return "The server doesn't support this"
        case .invalidSmb, .ioTimeout, .networkNameDeleted, .userSessionDeleted,
             .connectionDisconnected, .connectionReset, .connectionAborted: return connectionLost
        case .objectNameCollision: return "There's already something with that name here"
        }
    }

    /// libsmb2 turns NT statuses into errno values (nterror_to_errno); the text above wins when it names one.
    static func posixText(_ code: Int32) -> String? {
        switch code {
        case ECONNREFUSED: return wrongLogin // STATUS_LOGON_FAILURE (the TCP probe catches a refused port first)
        case EACCES, EPERM: return "This user isn't allowed to open that folder"
        case ENOENT: return "That folder or file isn't on the server any more"
        case EEXIST: return "There's already something with that name here"
        case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return couldntReach
        case ENETRESET, ENOTCONN, ECONNRESET, EPIPE, ECONNABORTED: return connectionLost
        default: return nil
        }
    }

    /// True when the error means the session is gone, so one retry with a fresh connection may work.
    static func isDropped(_ e: Error) -> Bool {
        switch e {
        case is SmbError: return false // our own, already-worded problems
        case is SmbSocketError: return false // the server is off: a reconnect would fail the same way
        case let s as SmbStatusError:
            return [.networkNameDeleted, .userSessionDeleted, .invalidSmb, .ioTimeout,
                    .connectionDisconnected, .connectionReset, .connectionAborted].contains(s.status)
        case is SmbTransportError: return true
        default: break
        }
        let ns = e as NSError
        if ns.domain == NSPOSIXErrorDomain {
            let text = ns.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
            if let status = SmbStatus.find(in: text) {
                return isDropped(SmbStatusError(status, ""))
            }
            switch Int32(ns.code) {
            case ENETRESET, ENOTCONN, ECONNRESET, EPIPE, ECONNABORTED, ETIMEDOUT, EIO, EBADF, ECANCELED, ESHUTDOWN:
                return true
            default:
                return false
            }
        }
        if let u = underlying(of: e) { return isDropped(u) }
        return false
    }

    private static func underlying(of e: Error) -> Error? {
        if let se = e as? SmbError { return se.underlying }
        if e is SmbStatusError || e is SmbTransportError || e is SmbSocketError { return nil }
        return (e as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }

    private static func message(of e: Error) -> String {
        if let se = e as? SmbError { return se.message }
        let ns = e as NSError
        // libsmb2's own texts ("Error code 5: …") are technical; people get the fallback sentence instead.
        if ns.domain == NSPOSIXErrorDomain { return "" }
        if !(type(of: e) is NSError.Type), !(e is LocalizedError) { return String(describing: e) }
        return ns.localizedDescription
    }
}
