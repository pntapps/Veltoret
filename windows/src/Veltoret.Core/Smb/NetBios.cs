using System.Text;

namespace Veltoret.Core.Smb;

/// <summary>
/// The tiny bit of NetBIOS used to put a name on a server found by address: a "node status" query (UDP 137)
/// asks a machine for its names, as Windows' <c>nbtstat -A</c> does. Routers and NAS boxes running Samba
/// usually answer even when they don't announce themselves.
/// </summary>
public static class NetBios
{
    public const int Port = 137;

    /// <summary>A node status (NBSTAT) request for the wildcard name "*".</summary>
    public static byte[] NodeStatusQuery(int transactionId)
    {
        var o = new byte[50];
        o[0] = (byte)(transactionId >> 8);
        o[1] = (byte)transactionId;
        o[5] = 1; // one question
        o[12] = 32; // encoded name length
        // "*" padded with zeros to 16 bytes, each byte split into two letters ('A' + nibble).
        var raw = new byte[16];
        raw[0] = (byte)'*';
        for (var i = 0; i < raw.Length; i++)
        {
            o[13 + i * 2] = (byte)('A' + ((raw[i] >> 4) & 0xF));
            o[14 + i * 2] = (byte)('A' + (raw[i] & 0xF));
        }
        // o[45] = 0 ends the name; type NBSTAT (0x21), class IN (1).
        o[47] = 0x21;
        o[49] = 1;
        return o;
    }

    /// <summary>
    /// The machine's own name from a node status answer: the unique "file server" name (suffix 0x20), else its
    /// unique workstation name (0x00). Null if the answer can't be read.
    /// </summary>
    public static string? ParseNodeStatus(byte[] data, int? length = null)
    {
        var len = length ?? data.Length;
        try
        {
            var offset = 12;
            while (data[offset] != 0) offset += data[offset] + 1;
            offset += 1 + 2 + 2 + 4 + 2; // end of name, type, class, TTL, data length
            int count = data[offset];
            offset += 1;
            var unique = new List<(string Name, int Suffix)>();
            for (var i = 0; i < count; i++)
            {
                var start = offset + i * 18;
                if (start + 18 > len) continue;
                var name = Encoding.ASCII.GetString(data, start, 15).Trim();
                var suffix = data[start + 15];
                var group = (data[start + 16] & 0x80) != 0;
                if (!group && name.Length > 0) unique.Add((name, suffix));
            }
            foreach (var u in unique) if (u.Suffix == 0x20) return u.Name;
            foreach (var u in unique) if (u.Suffix == 0x00) return u.Name;
            return null;
        }
        catch
        {
            return null;
        }
    }
}
