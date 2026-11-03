using System.Net.Sockets;
using System.Text;
using Avalonia.Threading;
using Adawat.Core;

namespace Adawat.Linux.Desktop;

/// <summary>Lets a second "adawat --wheel FILE…" (from a file manager's menu) hand its files to the running app, which
/// opens the wheel for them. The running app listens on $XDG_RUNTIME_DIR/adawat/app.sock.</summary>
public static class Instance
{
    private static Socket? _listener;

    private static string SocketPath => Path.Combine(Path.GetDirectoryName(ShellDragWatch.SocketPath)!, "app.sock");

    /// <summary>Sends <paramref name="files"/> to the running app; false when none is running.</summary>
    public static bool Forward(IReadOnlyList<string> files)
    {
        if (!File.Exists(SocketPath)) return false;
        try
        {
            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            socket.Connect(new UnixDomainSocketEndPoint(SocketPath));
            socket.Send(Encoding.UTF8.GetBytes(string.Join("\n", files) + "\n\n"));
            return true;
        }
        catch (SocketException) { return false; }
    }

    public static void Listen(Action<IReadOnlyList<string>> open)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SocketPath)!);
            if (File.Exists(SocketPath)) File.Delete(SocketPath);
            _listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            _listener.Bind(new UnixDomainSocketEndPoint(SocketPath));
            File.SetUnixFileMode(SocketPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            _listener.Listen(4);
            _ = Accept(_listener, open);
        }
        catch (Exception e) when (e is IOException or SocketException) { Log.Write($"instance socket: {e.Message}"); }
        // A wheel asked for on the command line of the first launch opens too.
        var args = Environment.GetCommandLineArgs();
        if (args.Length > 2 && args[1] == "--wheel")
        {
            var files = args.Skip(2).Select(Path.GetFullPath).ToList();
            Dispatcher.UIThread.Post(() => open(files), DispatcherPriority.Background);
        }
    }

    private static async Task Accept(Socket listener, Action<IReadOnlyList<string>> open)
    {
        while (true)
        {
            Socket client;
            try { client = await listener.AcceptAsync(); }
            catch (Exception e) when (e is ObjectDisposedException or SocketException) { return; }
            using (client)
            using (var reader = new StreamReader(new NetworkStream(client), Encoding.UTF8))
            {
                var files = new List<string>();
                while (await reader.ReadLineAsync() is { Length: > 0 } line) files.Add(line);
                if (files.Count > 0) Dispatcher.UIThread.Post(() => open(files));
            }
        }
    }

    public static void Stop()
    {
        _listener?.Dispose();
        try { File.Delete(SocketPath); } catch (IOException) { }
    }
}
