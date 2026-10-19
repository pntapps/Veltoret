using System.Buffers.Binary;
using System.Text;

namespace Veltoret.Core.Cast;

/// <summary>
/// The Cast v2 protobuf <c>extensions.api.cast_channel.CastMessage</c>, hand-encoded (proto2, 7 fields):
/// 1 protocol_version (varint, 0), 2 source_id, 3 destination_id, 4 namespace, 5 payload_type (varint: 0 STRING,
/// 1 BINARY), 6 payload_utf8, 7 payload_binary. On the wire each message is a 4-byte big-endian length + the bytes.
/// </summary>
public sealed record CastMessage(string SourceId, string DestinationId, string Namespace, string? PayloadUtf8, byte[]? PayloadBinary = null)
{
    public const string NsConnection = "urn:x-cast:com.google.cast.tp.connection";
    public const string NsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
    public const string NsReceiver = "urn:x-cast:com.google.cast.receiver";
    public const string NsMedia = "urn:x-cast:com.google.cast.media";

    public byte[] Encode()
    {
        using var ms = new MemoryStream();
        WriteVarintField(ms, 1, 0);
        WriteStringField(ms, 2, SourceId);
        WriteStringField(ms, 3, DestinationId);
        WriteStringField(ms, 4, Namespace);
        WriteVarintField(ms, 5, PayloadBinary != null ? 1UL : 0UL);
        if (PayloadBinary != null) WriteBytesField(ms, 7, PayloadBinary);
        else WriteStringField(ms, 6, PayloadUtf8 ?? "");
        return ms.ToArray();
    }

    /// <summary>The message with its 4-byte big-endian length prefix.</summary>
    public byte[] Frame()
    {
        var body = Encode();
        var frame = new byte[4 + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)body.Length);
        body.CopyTo(frame, 4);
        return frame;
    }

    public static CastMessage Decode(ReadOnlySpan<byte> data)
    {
        string source = "", destination = "", ns = "";
        string? utf8 = null;
        byte[]? binary = null;
        var p = 0;
        while (p < data.Length)
        {
            var key = ReadVarint(data, ref p);
            var field = (int)(key >> 3);
            var wire = (int)(key & 7);
            switch (wire)
            {
                case 0:
                    ReadVarint(data, ref p);
                    break;
                case 2:
                    var len = (int)ReadVarint(data, ref p);
                    if (len < 0 || p + len > data.Length) throw new InvalidDataException("Bad length");
                    var bytes = data.Slice(p, len);
                    p += len;
                    switch (field)
                    {
                        case 2: source = Encoding.UTF8.GetString(bytes); break;
                        case 3: destination = Encoding.UTF8.GetString(bytes); break;
                        case 4: ns = Encoding.UTF8.GetString(bytes); break;
                        case 6: utf8 = Encoding.UTF8.GetString(bytes); break;
                        case 7: binary = bytes.ToArray(); break;
                    }
                    break;
                case 1:
                    p += 8;
                    break;
                case 5:
                    p += 4;
                    break;
                default:
                    throw new InvalidDataException("Bad wire type");
            }
        }
        return new CastMessage(source, destination, ns, utf8, binary);
    }

    private static void WriteVarint(Stream s, ulong v)
    {
        while (v >= 0x80)
        {
            s.WriteByte((byte)(v | 0x80));
            v >>= 7;
        }
        s.WriteByte((byte)v);
    }

    private static void WriteVarintField(Stream s, int field, ulong v)
    {
        WriteVarint(s, (ulong)(field << 3));
        WriteVarint(s, v);
    }

    private static void WriteStringField(Stream s, int field, string value) => WriteBytesField(s, field, Encoding.UTF8.GetBytes(value));

    private static void WriteBytesField(Stream s, int field, byte[] value)
    {
        WriteVarint(s, (ulong)((field << 3) | 2));
        WriteVarint(s, (ulong)value.Length);
        s.Write(value);
    }

    private static ulong ReadVarint(ReadOnlySpan<byte> data, ref int p)
    {
        ulong v = 0;
        var shift = 0;
        while (true)
        {
            if (p >= data.Length || shift > 63) throw new InvalidDataException("Bad varint");
            var b = data[p++];
            v |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return v;
            shift += 7;
        }
    }
}
