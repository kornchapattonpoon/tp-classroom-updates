using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace TPClassroom.Core;

/// <summary>
/// UDP broadcast discovery on port 52801 (see PROTOCOL.md): students announce themselves,
/// teachers listen. No IP addresses to type and no internet needed.
/// </summary>
sealed class Discovery : IDisposable
{
    readonly UdpClient udp;

    /// <summary>Raised on the thread that called Start() (the UI thread).</summary>
    public event Action<DiscoveryPacket, string>? PacketReceived;

    public Discovery()
    {
        udp = new UdpClient(AddressFamily.InterNetwork);
        udp.ExclusiveAddressUse = false;
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        try
        {
            // Stop Windows from failing receives after an ICMP "port unreachable".
            const int SIO_UDP_CONNRESET = -1744830452;
            udp.Client.IOControl(SIO_UDP_CONNRESET, new byte[] { 0 }, null);
        }
        catch
        {
            // Not available everywhere; harmless.
        }
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, Ports.Udp));
        udp.EnableBroadcast = true;
    }

    public void Start() => _ = ReceiveLoopAsync();

    async Task ReceiveLoopAsync()
    {
        while (true)
        {
            UdpReceiveResult result;
            try
            {
                result = await udp.ReceiveAsync();
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (SocketException)
            {
                continue;
            }
            try
            {
                var packet = JsonSerializer.Deserialize<DiscoveryPacket>(result.Buffer, Json.Options);
                if (packet != null && packet.Tpc == 1)
                    PacketReceived?.Invoke(packet, result.RemoteEndPoint.Address.MapToIPv4().ToString());
            }
            catch (JsonException)
            {
                // Not ours.
            }
        }
    }

    /// <summary>Sends to every local network (directed broadcasts + 255.255.255.255).</summary>
    public void Broadcast(DiscoveryPacket packet)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(packet, Json.Options);
        var targets = BroadcastAddresses().Append(IPAddress.Broadcast).Select(a => a.ToString()).Distinct();
        foreach (var target in targets) Send(data, IPAddress.Parse(target));
    }

    /// <summary>Sends straight to one address (remembered computers).</summary>
    public void SendTo(DiscoveryPacket packet, string host)
    {
        if (!IPAddress.TryParse(host, out var address)) return;
        Send(JsonSerializer.SerializeToUtf8Bytes(packet, Json.Options), address);
    }

    void Send(byte[] data, IPAddress address)
    {
        try
        {
            udp.Send(data, data.Length, new IPEndPoint(address, Ports.Udp));
        }
        catch (SocketException)
        {
            // Network not available right now.
        }
    }

    static IEnumerable<IPAddress> BroadcastAddresses()
    {
        var result = new List<IPAddress>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var ip = unicast.Address.GetAddressBytes();
                    var mask = unicast.IPv4Mask.GetAddressBytes();
                    if (mask.Length != 4) continue;
                    var broadcast = new byte[4];
                    for (int i = 0; i < 4; i++) broadcast[i] = (byte)(ip[i] | ~mask[i]);
                    result.Add(new IPAddress(broadcast));
                }
            }
        }
        catch (NetworkInformationException)
        {
            // Fall back to 255.255.255.255 only.
        }
        return result;
    }

    public void Dispose() => udp.Dispose();
}
