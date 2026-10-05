using System.Text.Json.Nodes;

namespace ContextOS.Windows;

internal static class ShellSelfTest
{
    internal static async Task<int> RunAsync(CoreContract contract)
    {
        try
        {
            string shared = contract.CopyPayload().ToJsonString();
            var mismatched = contract.CopyPayload(); mismatched["version"] = "0.0.0";
            if (contract.Matches(mismatched.ToJsonString())) return 1;
            // Changed versions must stop before doctor can claim readiness.
            var mismatch = await new RuntimeInspector(contract, new FixtureCommands(shared, mismatched.ToJsonString())).InspectAsync();
            if (mismatch.ContractMatches || mismatch.CoreReady) return 2;
            var unexpectedReady = await new RuntimeInspector(contract, new FixtureCommands(shared, shared, true)).InspectAsync();
            if (unexpectedReady.ContractMatches || unexpectedReady.CoreReady) return 3;
            var inspected = await new RuntimeInspector(contract).InspectAsync();
            if (!inspected.ContractMatches || inspected.CoreReady) return 4;
            var model = new DashboardViewModel(new RuntimeInspector(contract), contract.Version);
            var window = new MainWindow(model);
            if (window.InformationTabCount != 3 || model.CanConnect) return 5;
            // Load and lay out XAML without showing a window or touching config.
            window.Measure(new System.Windows.Size(860, 780));
            window.Arrange(new System.Windows.Rect(0, 0, 860, 780));
            window.Close();
            return 0;
        }
        catch (Exception) { return 6; }
    }
    private sealed class FixtureCommands(string cli, string mcp, bool ready = false) : IRuntimeCommands
    {
        public Task<CommandResult> RunAsync(string binary, params string[] arguments)
        {
            if (arguments[0] is "contract" or "--contract")
                return Task.FromResult(new CommandResult(0, binary == "contextos" ? cli : mcp));
            var report = new JsonObject { ["version"] = CoreContract.Parse(cli)["version"]!.DeepClone(), ["platform"] = "windows",
                ["readyToConnect"] = ready, ["agentToolCallVerified"] = false };
            return Task.FromResult(new CommandResult(ready ? 0 : 1, report.ToJsonString()));
        }
    }
}
