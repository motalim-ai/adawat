namespace Adawat.Core;

public enum WheelMode { Convert, Tools, Actions }

/// <summary>Files in, result files out. Runs off the UI thread unless it says otherwise.</summary>
public delegate Task<IReadOnlyList<string>> OperationWork(IReadOnlyList<string> files, OperationContext context);

/// <summary>One choice on the wheel: a conversion, a tool or an action.</summary>
public sealed record AdawatOperation(string Id, string Title, string Icon, OperationWork Run)
{
    /// <summary>Format name drawn alone in the petal instead of an icon, such as "PNG".</summary>
    public string? Badge { get; init; }
    /// <summary>Shorter petal label for tools and actions, such as "METADATA".</summary>
    public string? Short { get; init; }
    /// <summary>Whether the result opens in a Float when that setting is on.</summary>
    public bool ProducesFiles { get; init; } = true;
    /// <summary>The options window this choice opens first, by name; the app knows the windows. Run stays the
    /// one-step version with saved defaults, used from the command line.</summary>
    public string? Window { get; init; }

    public string WheelLabel => Badge ?? L10n.Upper(L10n.T(Short ?? Title));
}

/// <summary>How an operation reports back: progress for the toast, and an optional closing message. It also carries the
/// user's Cancel: external tools stop with it, and loops stop at their next <see cref="Progress"/> or <see cref="ThrowIfCancelled"/>.</summary>
public sealed class OperationContext
{
    private readonly Action<string>? _report;
    private readonly Action<double>? _progress;

    public OperationContext(Action<string>? report = null, Action<double>? progress = null, CancellationToken cancellation = default)
    {
        _report = report;
        _progress = progress;
        Cancellation = cancellation;
    }

    public CancellationToken Cancellation { get; }
    public string? Message { get; private set; }

    /// <summary>Runs <paramref name="work"/> so that every external tool it starts is stopped when this context is cancelled,
    /// including the ones started without a token of their own. Call it from the task that does the work.</summary>
    public Task<IReadOnlyList<string>> Run(OperationWork work, IReadOnlyList<string> files)
    {
        ProcessRunner.Ambient.Value = Cancellation;
        return work(files, this);
    }

    /// <summary>Stops the operation here if the user cancelled it. Call it between files, pages and entries.</summary>
    public void ThrowIfCancelled() => Cancellation.ThrowIfCancellationRequested();

    public void Report(string text) => _report?.Invoke(L10n.T(text));

    /// <summary>Fraction done (0…1) of the whole operation. A cancelled operation stops here.</summary>
    public void Progress(double fraction)
    {
        ThrowIfCancelled();
        Show(fraction);
    }

    /// <summary>Maps one file's own 0…1 progress onto the whole operation. A cancelled operation stops here; the callback
    /// itself never throws, since tools call it from their output threads.</summary>
    public Action<double> ProgressFor(int index, int count)
    {
        ThrowIfCancelled();
        return fraction => Show((index + fraction) / Math.Max(count, 1));
    }

    private void Show(double fraction) => _progress?.Invoke(Math.Clamp(fraction, 0, 1));

    /// <summary>A message shown in the finish toast instead of the default one.</summary>
    public void Finish(string text) => Message = text;
}

public sealed class AdawatException(string message) : Exception(message)
{
    public override string Message => L10n.T(base.Message);
}
