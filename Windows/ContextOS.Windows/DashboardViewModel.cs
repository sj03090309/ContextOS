using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace ContextOS.Windows;

internal sealed class DashboardViewModel : INotifyPropertyChanged
{
    private readonly RuntimeInspector inspector;
    private bool inspecting;
    private string status = "Windows 기능 준비 중", detail = "동봉된 실행 파일을 확인할 수 있습니다.", lastChecked = "설치 확인 전";
    public string VersionLabel { get; }
    public string Status { get => status; private set { status = value; Changed(); } }
    public string Detail { get => detail; private set { detail = value; Changed(); } }
    public string LastChecked { get => lastChecked; private set { lastChecked = value; Changed(); } }
    public ObservableCollection<CheckRow> Checks { get; } = new();
    public ICommand InspectCommand { get; }
    // Preparation UI has no command that changes projects or agent settings.
    internal bool CanConnect => false;
    public event PropertyChangedEventHandler? PropertyChanged;
    internal DashboardViewModel(RuntimeInspector inspector, string version)
    {
        this.inspector = inspector; VersionLabel = version; InspectCommand = new AsyncCommand(InspectAsync);
    }
    internal async Task InspectAsync()
    {
        if (inspecting) return;
        inspecting = true;
        try
        {
            Status = "설치 확인 중";
            var result = await inspector.InspectAsync();
            Status = result.Status; Detail = result.Detail; Checks.Clear();
            foreach (var row in result.Checks) Checks.Add(row);
            LastChecked = $"확인 {DateTime.Now:t}";
        }
        finally { inspecting = false; }
    }
    private void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

internal sealed class AsyncCommand(Func<Task> action) : ICommand
{
    private bool running;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !running;
    public async void Execute(object? parameter)
    {
        if (running) return;
        running = true; CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        try { await action(); } finally { running = false; CanExecuteChanged?.Invoke(this, EventArgs.Empty); }
    }
}
