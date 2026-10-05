using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ContextOS.Windows;

internal sealed class CoreContract
{
    internal string Version { get; }
    private readonly JsonNode payload;
    private CoreContract(JsonNode payload, string version) { this.payload = payload; Version = version; }
    internal static CoreContract LoadBundled()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ContextOS.CoreContract.json")
            ?? throw new InvalidDataException("Missing shared contract");
        var payload = JsonNode.Parse(stream) ?? throw new InvalidDataException("Empty shared contract");
        string version = payload["version"]?.GetValue<string>() ?? "";
        string? assemblyVersion = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (payload["schema_version"]?.GetValue<int>() != 1 ||
            !Regex.IsMatch(version, @"^[0-9]+\.[0-9]+\.[0-9]+$", RegexOptions.CultureInvariant) || version != assemblyVersion)
            throw new InvalidDataException("Shared version mismatch");
        return new CoreContract(payload, version);
    }
    internal bool Matches(string json) => JsonNode.DeepEquals(payload, Parse(json));
    internal JsonNode CopyPayload() => payload.DeepClone();
    internal static JsonNode Parse(string json) => JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { MaxDepth = 32 })
        ?? throw new InvalidDataException("Empty runtime report");
}

internal sealed record CheckRow(string Label, string Detail);
internal sealed record InspectionResult(bool ContractMatches, bool CoreReady, string Status, string Detail, IReadOnlyList<CheckRow> Checks);
internal sealed record CommandResult(int ExitCode, string Output);
internal interface IRuntimeCommands { Task<CommandResult> RunAsync(string binary, params string[] arguments); }

/// Runs only the owned, bundled peers. No shell, PATH lookup, agent-config read,
/// project argument, account token or raw stderr appears in the UI.
internal sealed class BundledRuntimeCommands : IRuntimeCommands
{
    public async Task<CommandResult> RunAsync(string binary, params string[] arguments)
    {
        if (!OperatingSystem.IsWindows() || binary is not ("contextos" or "contextos-mcp"))
            throw new InvalidDataException("Unsupported runtime");
        var directory = Path.Combine(AppContext.BaseDirectory, "runtime");
        string file = Path.Combine(directory, binary + ".exe");
        if (!File.Exists(file) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0 ||
            (File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new FileNotFoundException();
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo(file)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false, true), StandardErrorEncoding = new UTF8Encoding(false, true)
        };
        foreach (string argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        if (!process.Start()) throw new IOException("Diagnostic could not start");
        try
        {
            var output = ReadBoundedAsync(process.StandardOutput, timeout.Token);
            var error = ReadBoundedAsync(process.StandardError, timeout.Token);
            await Task.WhenAll(output, error, process.WaitForExitAsync(timeout.Token));
            return new CommandResult(process.ExitCode, await output);
        }
        finally
        {
            // Only this method's own diagnostic child can be stopped.
            if (!process.HasExited) process.Kill(entireProcessTree: false);
        }
    }
    private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken token)
    {
        var output = new StringBuilder(); var buffer = new char[4096];
        while (true)
        {
            int count = await reader.ReadAsync(buffer.AsMemory(), token);
            if (count == 0) return output.ToString();
            if (output.Length + count > 131_072) throw new InvalidDataException("Diagnostic output is too large");
            output.Append(buffer, 0, count);
        }
    }
}

internal sealed class RuntimeInspector(CoreContract contract, IRuntimeCommands? commands = null)
{
    private readonly IRuntimeCommands commands = commands ?? new BundledRuntimeCommands();
    internal async Task<InspectionResult> InspectAsync()
    {
        try
        {
            var cli = await commands.RunAsync("contextos", "contract");
            var mcp = await commands.RunAsync("contextos-mcp", "--contract");
            if (cli.ExitCode != 0 || mcp.ExitCode != 0 || !contract.Matches(cli.Output) || !contract.Matches(mcp.Output))
                return Blocked("버전 확인 필요", "화면·실행 파일의 버전 또는 도구 목록이 다릅니다. 같은 버전의 전체 앱을 다시 준비해 주세요.");
            var doctor = await commands.RunAsync("contextos", "doctor", "--json");
            var report = CoreContract.Parse(doctor.Output);
            if (report["version"]?.GetValue<string>() != contract.Version || report["platform"]?.GetValue<string>() != "windows" ||
                report["readyToConnect"]?.GetValue<bool>() is not false || report["agentToolCallVerified"]?.GetValue<bool>() is not false || doctor.ExitCode != 1)
                return Blocked("Windows 검증 필요", "이 준비 화면이 예상한 Windows 보호 상태를 확인하지 못했습니다.");
            return new InspectionResult(true, false, "Windows 기능 준비 중",
                "화면과 실행 파일의 버전·도구 목록이 일치합니다. 프로젝트 읽기와 AI 설정 변경은 아직 사용할 수 없습니다.",
                new[] { new CheckRow("같은 버전", contract.Version + " 확인"), new CheckRow("Windows 파일 보호", "핵심 기능 활성화 전"),
                    new CheckRow("실제 AI 호출", "검증 전") });
        }
        catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException or FormatException
                                               or Win32Exception or OperationCanceledException or DecoderFallbackException)
        {
            return Blocked("설치 확인 필요", "동봉된 실행 파일을 확인할 수 없습니다. 전체 앱을 같은 위치에 준비한 뒤 다시 확인해 주세요.");
        }
    }
    private static InspectionResult Blocked(string status, string detail) => new(false, false, status, detail, Array.Empty<CheckRow>());
}
