using System.Net.Sockets;
using SMBLibrary;

namespace Veltoret.Core.Smb;

/// <summary>A network share problem, worded for people (wrong password, server off, folder gone…).</summary>
public sealed class SmbException(string message, Exception? inner = null) : IOException(message, inner);

/// <summary>An SMB request the server answered with an error status.</summary>
public sealed class SmbStatusException(NTStatus status, string operation)
    : IOException($"{operation} failed: {status}")
{
    public NTStatus Status { get; } = status;
}

/// <summary>The connection to the server is gone (closed, timed out, or the request got no answer).</summary>
public sealed class SmbTransportException(string message, Exception? inner = null) : IOException(message, inner);

public static class SmbErrors
{
    public const string WrongLogin = "Wrong username or password";
    public const string AccountDisabled = "This user account is disabled on the server";
    public const string CouldntReach = "Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi.";
    public const string UnknownHost = "Couldn't find that server on your network. Check the address.";
    public const string ConnectionLost = "The connection to the server was lost";
    public const string Fallback = "Something went wrong talking to the server";

    /// <summary>A sentence for the user. Unknown errors keep their own message.</summary>
    public static string Describe(Exception e)
    {
        for (Exception? cause = e; cause != null; cause = cause.InnerException)
        {
            switch (cause)
            {
                case SmbException se:
                    return se.Message;
                case SocketException { SocketErrorCode: SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain }:
                    return UnknownHost;
                case SocketException:
                case TimeoutException:
                    return CouldntReach;
                case SmbStatusException s:
                    var text = StatusText(s.Status);
                    if (text != null) return text;
                    break;
                case SmbTransportException:
                    return ConnectionLost;
            }
        }
        return string.IsNullOrWhiteSpace(e.Message) ? Fallback : e.Message;
    }

    internal static string? StatusText(NTStatus status) => status switch
    {
        NTStatus.STATUS_LOGON_FAILURE => WrongLogin,
        NTStatus.STATUS_ACCOUNT_DISABLED => AccountDisabled,
        NTStatus.STATUS_PASSWORD_EXPIRED => "This user's password has expired on the server",
        NTStatus.STATUS_ACCESS_DENIED => "This user isn't allowed to open that folder",
        NTStatus.STATUS_BAD_NETWORK_NAME => "The server has no shared folder with that name",
        NTStatus.STATUS_OBJECT_NAME_NOT_FOUND or NTStatus.STATUS_OBJECT_PATH_NOT_FOUND => "That folder or file isn't on the server any more",
        NTStatus.STATUS_NOT_SUPPORTED => "The server doesn't support this",
        // SMBLibrary reports a request that got no answer (connection dropped, timed out) as STATUS_INVALID_SMB.
        NTStatus.STATUS_INVALID_SMB or NTStatus.STATUS_IO_TIMEOUT or NTStatus.STATUS_NETWORK_NAME_DELETED
            or NTStatus.STATUS_USER_SESSION_DELETED => ConnectionLost,
        _ => null,
    };

    /// <summary>True when the error means the session is gone, so one retry with a fresh connection may work.</summary>
    internal static bool IsDropped(Exception e) => e switch
    {
        SmbException => false, // our own, already-worded problems (removed server, not a shared folder…)
        SmbStatusException s => s.Status is NTStatus.STATUS_NETWORK_NAME_DELETED or NTStatus.STATUS_USER_SESSION_DELETED
            or NTStatus.STATUS_INVALID_SMB or NTStatus.STATUS_IO_TIMEOUT,
        SmbTransportException or TimeoutException or IOException or SocketException or ObjectDisposedException => true,
        AggregateException a => a.InnerExceptions.Any(IsDropped),
        _ => e.InnerException != null && IsDropped(e.InnerException),
    };
}
