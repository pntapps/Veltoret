using Windows.Media.SpeechRecognition;

namespace Veltoret.App.Plans;

/// <summary>
/// The Search mic (Android: rememberVoiceInput "Say a title, actor or director"): Windows dictation, one phrase.
/// Returns null when nothing was heard or speech isn't available, after telling the user why.
/// </summary>
public static class VoiceSearch
{
    /// <summary>Windows: "Online speech recognition" is off in Settings → Privacy → Speech.</summary>
    private const int PrivacyNotAccepted = unchecked((int)0x80045509);

    private static bool _busy;

    public static async Task<string?> Listen()
    {
        if (_busy) return null;
        _busy = true;
        try
        {
            using var recognizer = new SpeechRecognizer();
            recognizer.Constraints.Add(new SpeechRecognitionTopicConstraint(SpeechRecognitionScenario.Dictation, "search"));
            recognizer.Timeouts.InitialSilenceTimeout = TimeSpan.FromSeconds(6);
            recognizer.Timeouts.EndSilenceTimeout = TimeSpan.FromSeconds(1.2);
            var compiled = await recognizer.CompileConstraintsAsync();
            if (compiled.Status != SpeechRecognitionResultStatus.Success)
            {
                Unavailable();
                return null;
            }
            Controls.Toast.Show("Listening… Say a title, actor or director");
            var result = await recognizer.RecognizeAsync();
            if (result.Status == SpeechRecognitionResultStatus.Success && !string.IsNullOrWhiteSpace(result.Text))
                return result.Text.Trim();
            if (result.Status == SpeechRecognitionResultStatus.UserCanceled) return null;
            Controls.Toast.Show("Didn't catch that. Try again.");
            return null;
        }
        catch (Exception ex) when (ex.HResult == PrivacyNotAccepted)
        {
            Controls.Toast.Show("Turn on online speech recognition to search by voice.", "Settings",
                () => Ui.OpenUrl("ms-settings:privacy-speech"));
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            Controls.Toast.Show("Veltoret can't use the microphone. Allow it in Windows Settings.", "Settings",
                () => Ui.OpenUrl("ms-settings:privacy-microphone"));
            return null;
        }
        catch (Exception)
        {
            Unavailable();
            return null;
        }
        finally
        {
            _busy = false;
        }
    }

    private static void Unavailable() =>
        Controls.Toast.Show("Voice search isn't available on this PC. Check your microphone and speech settings.", "Settings",
            () => Ui.OpenUrl("ms-settings:privacy-speech"));
}
