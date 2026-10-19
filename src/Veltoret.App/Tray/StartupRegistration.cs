using Microsoft.Win32;

namespace Veltoret.App.Tray;

/// <summary>
/// "Start with Windows": a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run that starts Veltoret
/// with --background (straight to the notification area, so reminders and alerts work after sign-in).
/// </summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Veltoret";

    public static string Command => $"\"{Environment.ProcessPath}\" --background";

    public static bool IsRegistered()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
        catch (Exception) { return false; }
    }

    /// <summary>Adds (with the current exe path) or removes the Run entry; false when the registry refused.</summary>
    public static bool Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled) key.SetValue(ValueName, Command, RegistryValueKind.String);
            else if (key.GetValue(ValueName) != null) key.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception ex)
        {
            App.Log(ex);
            return false;
        }
    }
}
