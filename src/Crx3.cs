using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

// Read-only verifier for CRX3 packages. Chromium still performs installation.
public static class Crx3
{
    // Chromium production Web Store publisher key hash. See THIRD_PARTY_NOTICES.md.
    private const string StoreKey = "61F7F2A6BFCF74CD0BC1FE2497CC9B04254C658F79F2145392867EA8366367CF";

    public sealed class Package
    {
        public string PublicKey { get; init; }
        public string Manifest { get; init; }
        public int ZipOffset { get; init; }
    }

    public static string ExtensionId(byte[] publicKey)
    {
        return FormatId(SHA256.HashData(publicKey).Take(16).ToArray());
    }

    private static string FormatId(byte[] id)
    {
        if (id.Length != 16) throw new InvalidDataException("Invalid CRX3 identifier.");
        return string.Concat(id.SelectMany(value => new[] { (char)('a' + (value >> 4)), (char)('a' + (value & 15)) }));
    }

    private static ulong ReadVarint(byte[] bytes, ref int offset)
    {
        ulong accumulated = 0;
        for (int shift = 0; shift <= 63; shift += 7)
        {
            if (offset >= bytes.Length) break;
            byte current = bytes[offset++];
            if (shift == 63 && current > 1) break;
            if ((current & 128) == 0) return accumulated | ((ulong)current << shift);
            accumulated |= (ulong)(current & 127) << shift;
        }
        throw new InvalidDataException("Invalid CRX3 varint.");
    }

    private static List<(int Number, byte[] Bytes)> ReadFields(byte[] bytes)
    {
        var fields = new List<(int, byte[])>();
        int offset = 0;
        while (offset < bytes.Length)
        {
            if (fields.Count == 64) throw new InvalidDataException("Too many CRX3 fields.");
            ulong tag = ReadVarint(bytes, ref offset);
            if (tag >> 3 == 0 || tag >> 3 > 536870911 || (tag & 7) != 2)
                throw new InvalidDataException("Unsupported CRX3 field.");
            ulong length = ReadVarint(bytes, ref offset);
            if (length > (ulong)(bytes.Length - offset)) throw new InvalidDataException("Truncated CRX3 field.");
            fields.Add(((int)(tag >> 3), bytes.AsSpan(offset, (int)length).ToArray()));
            offset += (int)length;
        }
        return fields;
    }

    private static byte[] Required(List<(int Number, byte[] Bytes)> fields, int number)
    {
        return fields.Single(field => field.Number == number).Bytes;
    }

    public static Package Verify(byte[] bytes, string expectedId, bool requireStoreKey)
    {
        if (bytes.Length < 13 || bytes.Length > 32 * 1024 * 1024 ||
            Encoding.ASCII.GetString(bytes, 0, 4) != "Cr24" || BitConverter.ToUInt32(bytes, 4) != 3)
            throw new InvalidDataException("Expected a bounded CRX3 package.");
        uint headerLength = BitConverter.ToUInt32(bytes, 8);
        if (headerLength > 1024 * 1024 || headerLength >= bytes.Length - 12)
            throw new InvalidDataException("Invalid CRX3 header length.");
        int zipOffset = 12 + (int)headerLength;
        var fields = ReadFields(bytes.AsSpan(12, (int)headerLength).ToArray());
        byte[] signed = Required(fields, 10000);
        if (FormatId(Required(ReadFields(signed), 1)) != expectedId)
            throw new InvalidDataException("Unexpected signed extension ID.");

        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.ASCII.GetBytes("CRX3 SignedData\0"));
        hash.AppendData(BitConverter.GetBytes(signed.Length));
        hash.AppendData(signed);
        hash.AppendData(bytes, zipOffset, bytes.Length - zipOffset);
        byte[] digest = hash.GetHashAndReset();
        byte[] developerKey = null;
        bool storeProof = false;
        foreach (var proof in fields.Where(field => field.Number == 2 || field.Number == 3))
        {
            var proofFields = ReadFields(proof.Bytes);
            byte[] key = Required(proofFields, 1);
            byte[] signature = Required(proofFields, 2);
            bool valid;
            if (proof.Number == 2)
            {
                using var rsa = RSA.Create();
                rsa.ImportSubjectPublicKeyInfo(key, out int consumed);
                valid = consumed == key.Length && rsa.VerifyHash(digest, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            }
            else
            {
                using var ec = ECDsa.Create();
                ec.ImportSubjectPublicKeyInfo(key, out int consumed);
                valid = consumed == key.Length && ec.VerifyHash(digest, signature, DSASignatureFormat.Rfc3279DerSequence);
            }
            if (!valid) throw new InvalidDataException("Invalid CRX3 signature.");
            if (ExtensionId(key) == expectedId) developerKey = key;
            if (Convert.ToHexString(SHA256.HashData(key)) == StoreKey) storeProof = true;
        }
        if (developerKey == null || (requireStoreKey && !storeProof))
            throw new InvalidDataException("Required CRX3 developer or Web Store publisher proof is missing.");

        using var stream = new MemoryStream(bytes, zipOffset, bytes.Length - zipOffset, false);
        using var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        var manifest = zip.Entries.Single(entry => string.Equals(entry.FullName, "manifest.json", StringComparison.OrdinalIgnoreCase));
        if (manifest.FullName != "manifest.json" || manifest.Length > 1024 * 1024)
            throw new InvalidDataException("Invalid CRX3 manifest.");
        using var reader = new StreamReader(manifest.Open(), new UTF8Encoding(false, true));
        char[] content = new char[1024 * 1024 + 1];
        int count = reader.ReadBlock(content, 0, content.Length);
        if (count == content.Length) throw new InvalidDataException("Extension manifest exceeds the size limit.");
        return new Package { PublicKey = Convert.ToBase64String(developerKey), Manifest = new string(content, 0, count), ZipOffset = zipOffset };
    }
}
