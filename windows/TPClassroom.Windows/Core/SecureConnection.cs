using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TPClassroom.Core;

/// <summary>
/// One encrypted teacher ↔ student connection (handshake + AES-256-GCM records, see PROTOCOL.md).
/// Events are raised on the thread that called Start() (the UI thread).
/// </summary>
sealed class SecureConnection
{
    const int MaxRecord = 16 * 1024 * 1024 + 64;
    static readonly byte[] Magic = Encoding.ASCII.GetBytes("TPC1");

    readonly TcpClient client;
    readonly NetworkStream stream;
    readonly bool isTeacher;
    readonly byte[] classKey;
    readonly SemaphoreSlim sendLock = new(1, 1);
    AesGcm? sendAes;
    AesGcm? receiveAes;
    ulong sendCounter;
    ulong receiveCounter;
    volatile bool cancelledByOwner;
    volatile bool closed;
    bool gotFirstRecord;

    public string RemoteAddress { get; }

    public event Action<NetMessage>? MessageReceived;
    public event Action<byte[]>? FrameReceived;
    public event Action<byte[]>? ChunkReceived;
    /// <summary>Connection ended (null reason = closed normally). Not raised after Cancel().</summary>
    public event Action<string?>? Closed;

    SecureConnection(TcpClient client, bool isTeacher, byte[] classKey)
    {
        this.client = client;
        this.isTeacher = isTeacher;
        this.classKey = classKey;
        client.NoDelay = true;
        stream = client.GetStream();
        RemoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.MapToIPv4().ToString() ?? "";
    }

    public static async Task<SecureConnection> ConnectAsync(string host, int port, byte[] classKey, CancellationToken token)
    {
        var tcp = new TcpClient(AddressFamily.InterNetwork);
        try
        {
            await tcp.ConnectAsync(host, port, token);
            var connection = new SecureConnection(tcp, true, classKey);
            await connection.HandshakeAsync(token);
            return connection;
        }
        catch
        {
            tcp.Dispose();
            throw;
        }
    }

    public static async Task<SecureConnection> AcceptAsync(TcpClient tcp, byte[] classKey, CancellationToken token)
    {
        var connection = new SecureConnection(tcp, false, classKey);
        await connection.HandshakeAsync(token);
        return connection;
    }

    async Task HandshakeAsync(CancellationToken token)
    {
        var localNonce = RandomNumberGenerator.GetBytes(32);
        var hello = new byte[36];
        Magic.CopyTo(hello, 0);
        localNonce.CopyTo(hello, 4);
        await stream.WriteAsync(hello, token);

        var remote = new byte[36];
        await stream.ReadExactlyAsync(remote, token);
        if (!remote.AsSpan(0, 4).SequenceEqual(Magic))
            throw new IOException("That device isn't running a compatible TP Classroom.");
        var remoteNonce = remote[4..];

        var salt = isTeacher ? Concat(localNonce, remoteNonce) : Concat(remoteNonce, localNonce);
        var teacherToStudent = HKDF.DeriveKey(HashAlgorithmName.SHA256, classKey, 32, salt,
                                              Encoding.UTF8.GetBytes("TPClassroom/v1/t2s"));
        var studentToTeacher = HKDF.DeriveKey(HashAlgorithmName.SHA256, classKey, 32, salt,
                                              Encoding.UTF8.GetBytes("TPClassroom/v1/s2t"));
        sendAes = new AesGcm(isTeacher ? teacherToStudent : studentToTeacher, 16);
        receiveAes = new AesGcm(isTeacher ? studentToTeacher : teacherToStudent, 16);
    }

    static byte[] Concat(byte[] a, byte[] b)
    {
        var result = new byte[a.Length + b.Length];
        a.CopyTo(result, 0);
        b.CopyTo(result, a.Length);
        return result;
    }

    static byte[] Nonce(ulong counter)
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), counter);
        return nonce;
    }

    /// <summary>Starts reading. Call on the UI thread so events arrive there.</summary>
    public void Start() => _ = ReceiveLoopAsync();

    /// <summary>Closes the connection without raising Closed.</summary>
    public void Cancel()
    {
        cancelledByOwner = true;
        CloseSocket();
    }

    void CloseSocket()
    {
        closed = true;
        try { client.Close(); } catch { /* already closed */ }
    }

    async Task ReceiveLoopAsync()
    {
        string? reason = null;
        try
        {
            var header = new byte[4];
            while (!closed)
            {
                await stream.ReadExactlyAsync(header);
                int length = BinaryPrimitives.ReadInt32BigEndian(header);
                if (length < 17 || length > MaxRecord) throw new IOException("Received damaged data.");
                var record = new byte[length];
                await stream.ReadExactlyAsync(record);

                byte[] plaintext;
                try
                {
                    plaintext = Open(record);
                }
                catch (CryptographicException)
                {
                    throw new IOException(gotFirstRecord ? "Received damaged data." : "The class code doesn't match.");
                }
                gotFirstRecord = true;
                Dispatch(plaintext);
            }
        }
        catch (EndOfStreamException)
        {
            reason = gotFirstRecord ? null : "The class code doesn't match.";
        }
        catch (IOException ex)
        {
            reason = ex.InnerException is SocketException ? "The connection was lost." : ex.Message;
        }
        catch (ObjectDisposedException)
        {
            reason = null;
        }
        catch (Exception ex)
        {
            reason = ex.Message;
        }
        finally
        {
            CloseSocket();
            if (!cancelledByOwner) Closed?.Invoke(reason);
        }
    }

    byte[] Open(byte[] record)
    {
        int cipherLength = record.Length - 16;
        var plaintext = new byte[cipherLength];
        receiveAes!.Decrypt(Nonce(receiveCounter), record.AsSpan(0, cipherLength), record.AsSpan(cipherLength, 16), plaintext);
        receiveCounter++;
        return plaintext;
    }

    void Dispatch(byte[] plaintext)
    {
        if (plaintext.Length == 0) return;
        var payload = plaintext.AsSpan(1).ToArray();
        switch (plaintext[0])
        {
            case 1:
                NetMessage? message = null;
                try { message = JsonSerializer.Deserialize<NetMessage>(payload, Json.Options); }
                catch (JsonException) { /* ignore messages we don't understand */ }
                if (message != null) MessageReceived?.Invoke(message);
                break;
            case 2:
                FrameReceived?.Invoke(payload);
                break;
            case 3:
                ChunkReceived?.Invoke(payload);
                break;
        }
    }

    public Task<bool> SendAsync(NetMessage message) =>
        SendRecordAsync(1, JsonSerializer.SerializeToUtf8Bytes(message, Json.Options));

    public Task<bool> SendFrameAsync(byte[] jpeg) => SendRecordAsync(2, jpeg);

    public Task<bool> SendChunkAsync(byte[] bytes) => SendRecordAsync(3, bytes);

    /// <summary>Thread-safe. Returns false if the connection is gone.</summary>
    async Task<bool> SendRecordAsync(byte type, byte[] payload)
    {
        if (closed) return false;
        await sendLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (closed || sendAes == null) return false;
            var plaintext = new byte[payload.Length + 1];
            plaintext[0] = type;
            payload.CopyTo(plaintext, 1);
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[16];
            sendAes.Encrypt(Nonce(sendCounter), plaintext, ciphertext, tag);
            sendCounter++;

            var packet = new byte[4 + ciphertext.Length + 16];
            BinaryPrimitives.WriteInt32BigEndian(packet, ciphertext.Length + 16);
            ciphertext.CopyTo(packet, 4);
            tag.CopyTo(packet, 4 + ciphertext.Length);
            await stream.WriteAsync(packet).ConfigureAwait(false);
            return true;
        }
        catch
        {
            CloseSocket();   // the receive loop notices and raises Closed
            return false;
        }
        finally
        {
            sendLock.Release();
        }
    }
}
