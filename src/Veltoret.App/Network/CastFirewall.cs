using System.Diagnostics;
using System.Windows;
using Veltoret.App.Controls;
using Veltoret.Core.Cast;

namespace Veltoret.App.Network;

/// <summary>
/// Windows Firewall hint. The TV fetches the video from this PC, so an inbound rule is needed; without one Windows
/// blocks it silently (or asked once and the user said no). When the receiver never reaches the cast server, offer
/// to add an inbound rule for Private networks; netsh runs elevated only after the user clicks "Allow".
/// </summary>
public static class CastFirewall
{
    public const string RuleName = "Veltoret (casting)";
    private static bool _offered;

    public static void Watch(CastController cast) =>
        cast.ReceiverUnreachable += () => Application.Current?.Dispatcher.BeginInvoke(() => _ = Offer());

    private static async Task Offer()
    {
        if (_offered) return;
        _offered = true;
        if (await RuleExists())
        {
            Toast.Show("The TV couldn't reach this PC. If this network is set to Public in Windows, set it to Private and try again.");
            return;
        }
        var allow = new DialogButton("Allow", DialogButtonKind.Primary) { IsDefault = true };
        var result = DialogWindow.Show(null, "Let the TV reach this PC?",
            DialogWindow.Message(
                "The TV couldn't load the video from this PC. Windows Firewall is probably blocking it.\n\n" +
                "Allow Veltoret to stream to TVs on private networks? Windows will ask for permission. " +
                "If your network is set to Public in Windows, set it to Private too."),
            DialogButton.Cancel("Not now"), allow);
        if (result != allow) return;
        if (AddRule()) Toast.Show("Veltoret can now stream to your TV. Try casting again.");
    }

    private static string ExePath => Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName ?? "";

    /// <summary>netsh can list rules without admin rights.</summary>
    private static async Task<bool> RuleExists()
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{RuleName}\"")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            };
            using var p = Process.Start(psi);
            if (p == null) return false;
            var output = await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            return p.ExitCode == 0 && output.Contains(RuleName, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e)
        {
            App.Log(e);
            return false;
        }
    }

    /// <summary>Adds the inbound rule through an elevated netsh (UAC prompt). False when cancelled or failed.</summary>
    public static bool AddRule()
    {
        try
        {
            var psi = new ProcessStartInfo("netsh",
                $"advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow program=\"{ExePath}\" enable=yes profile=private")
            {
                UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden,
            };
            using var p = Process.Start(psi);
            if (p == null) return false;
            p.WaitForExit(30_000);
            return p.HasExited && p.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // The user said no to the UAC prompt.
            return false;
        }
        catch (Exception e)
        {
            App.Log(e);
            return false;
        }
    }
}
