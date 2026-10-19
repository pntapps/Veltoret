using Veltoret.Core.Auth;

namespace Veltoret.Core.Tests.Drive;

public class LoopbackReceiverTests
{
    [Fact]
    public async Task ReceivesTheRedirectAndIgnoresOtherRequests()
    {
        using var receiver = new LoopbackReceiver();
        Assert.StartsWith("http://127.0.0.1:", receiver.RedirectUri);
        Assert.EndsWith("/", receiver.RedirectUri);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var wait = receiver.WaitForRedirect(q => LoopbackReceiver.Page("Veltoret is connected", "You can close this tab and go back to the app."), cts.Token);

        using var http = new HttpClient();
        var favicon = await http.GetAsync(receiver.RedirectUri + "favicon.ico", cts.Token);
        Assert.Equal(System.Net.HttpStatusCode.NotFound, favicon.StatusCode);
        var page = await http.GetStringAsync(receiver.RedirectUri + "?state=s%2Bt&code=4%2F0Ab_x&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive", cts.Token);
        Assert.Contains("Veltoret is connected", page);

        var query = await wait;
        Assert.Equal("4/0Ab_x", query["code"]);
        Assert.Equal("s+t", query["state"]);
        Assert.Equal("https://www.googleapis.com/auth/drive", query["scope"]);
    }

    [Fact]
    public async Task CancellingStopsWaiting()
    {
        using var receiver = new LoopbackReceiver();
        using var cts = new CancellationTokenSource();
        var wait = receiver.WaitForRedirect(_ => "", cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => wait);
    }
}
