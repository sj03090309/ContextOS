using System.Text.Json.Nodes;

namespace ContextOS.Windows;

internal static class ShellSelfTest
{
    private static int Report(int exitCode, string stage, string? exceptionType = null)
    {
        Console.WriteLine(new JsonObject { ["gui_self_test_passed"] = exitCode == 0,
            ["stage"] = stage, ["exit_code"] = exitCode, ["exception_type"] = exceptionType,
            ["windows_product_ready"] = false }.ToJsonString());
        return exitCode;
    }
    internal static async Task<int> RunAsync(CoreContract contract)
    {
        string stage = "embedded contract";
        try
        {
            string shared = contract.CopyPayload().ToJsonString();
            var mismatched = contract.CopyPayload(); mismatched["version"] = "0.0.0";
            if (contract.Matches(mismatched.ToJsonString())) return Report(1, stage);
            // Changed versions must stop before doctor can claim readiness.
            stage = "reject mismatched peers";
            var mismatch = await new RuntimeInspector(contract, new FixtureCommands(shared, mismatched.ToJsonString())).InspectAsync();
            if (mismatch.ContractMatches || mismatch.CoreReady) return Report(2, stage);
            stage = "reject unexpected readiness";
            var unexpectedReady = await new RuntimeInspector(contract, new FixtureCommands(shared, shared, true)).InspectAsync();
            if (unexpectedReady.ContractMatches || unexpectedReady.CoreReady) return Report(3, stage);
            stage = "bundled CLI and MCP";
            var inspected = await new RuntimeInspector(contract).InspectAsync();
            if (!inspected.ContractMatches || inspected.CoreReady) return Report(4, stage);
            stage = "three tabs and disabled connection";
            var model = new DashboardViewModel(new RuntimeInspector(contract), contract.Version);
            var window = new MainWindow(model);
            if (window.InformationTabCount != 3 || model.CanConnect) return Report(5, stage);
            // Load and lay out XAML without showing a window or touching config.
            stage = "headless XAML layout";
            window.Measure(new System.Windows.Size(860, 780));
            window.Arrange(new System.Windows.Rect(0, 0, 860, 780));
            window.Close();
            return Report(0, stage);
        }
        catch (Exception exception) { return Report(6, stage, exception.GetType().Name); }
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
