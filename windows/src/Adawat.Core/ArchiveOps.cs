using System.Formats.Tar;
using System.IO.Compression;
using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace Adawat.Core;

/// <summary>Packing into ZIP, TAR, TGZ and GZ, converting between them, and extracting nearly anything (RAR and 7-Zip included).</summary>
public static class ArchiveOps
{
    public static string Title(string format) => format.ToUpperInvariant();

    public static string? FormatOf(string path) => FileKinds.Ext(path) switch
    {
        "zip" => "zip", "tar" => "tar", "tgz" => "tgz", "gz" => "gz", _ => null,
    };

    public static async Task<IReadOnlyList<string>> Pack(IReadOnlyList<string> files, string format, OperationContext context)
    {
        context.Report($"Packing {files.Count} items");
        var name = files.Count == 1 ? Path.GetFileName(files[0].TrimEnd('\\', '/')) : "Archive";
        var output = format == "gz" ? Output.Unique(Path.Combine(Output.Directory(files[0]), Path.GetFileName(files[0]) + ".gz"))
                                    : Output.Named($"{name}.{(format == "tgz" ? "tar.gz" : format)}", files[0]);
        try
        {
            await Task.Run(() =>
            {
                switch (format)
                {
                    case "zip":
                        using (var zip = ZipFile.Open(output, ZipArchiveMode.Create))
                            foreach (var item in files) AddToZip(zip, item, Path.GetFileName(item.TrimEnd('\\', '/')), context);
                        break;
                    case "tar":
                        using (var stream = File.Create(output)) WriteTar(stream, files, context);
                        break;
                    case "tgz":
                        using (var stream = File.Create(output))
                        using (var gzip = new GZipStream(stream, CompressionLevel.Optimal)) WriteTar(gzip, files, context);
                        break;
                    case "gz":
                        using (var input = File.OpenRead(files[0]))
                        using (var stream = File.Create(output))
                        using (var gzip = new GZipStream(stream, CompressionLevel.Optimal)) input.CopyToAsync(gzip, context.Cancellation).GetAwaiter().GetResult();
                        break;
                }
            });
        }
        catch (OperationCanceledException)
        {
            File.Delete(output);
            throw;
        }
        return [output];
    }

    private static void AddToZip(ZipArchive zip, string path, string entryName, OperationContext context)
    {
        context.ThrowIfCancelled();
        if (Directory.Exists(path))
        {
            var entries = Directory.EnumerateFileSystemEntries(path).ToList();
            if (entries.Count == 0) zip.CreateEntry(entryName + "/");
            foreach (var child in entries) AddToZip(zip, child, entryName + "/" + Path.GetFileName(child), context);
            return;
        }
        zip.CreateEntryFromFile(path, entryName, CompressionLevel.Optimal);
    }

    private static void WriteTar(System.IO.Stream stream, IReadOnlyList<string> files, OperationContext context)
    {
        using var tar = new TarWriter(stream, TarEntryFormat.Pax, leaveOpen: true);
        void Add(string path, string name)
        {
            context.ThrowIfCancelled();
            if (Directory.Exists(path))
            {
                tar.WriteEntry(new PaxTarEntry(TarEntryType.Directory, name + "/"));
                foreach (var child in Directory.EnumerateFileSystemEntries(path)) Add(child, name + "/" + Path.GetFileName(child));
                return;
            }
            tar.WriteEntry(path, name);
        }
        foreach (var item in files) Add(item, Path.GetFileName(item.TrimEnd('\\', '/')));
    }

    /// <summary>Each archive unpacked into a folder named after it, beside it.</summary>
    public static async Task<IReadOnlyList<string>> Extract(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            context.Report($"Extracting {Path.GetFileName(file)}");
            var name = Path.GetFileName(file);
            foreach (var suffix in new[] { ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz", ".iso", ".cab" })
                if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) { name = name[..^suffix.Length]; break; }
            var folder = Output.Named(name, file);
            try
            {
                await Task.Run(() => ExtractTo(file, folder, context));
            }
            catch (OperationCanceledException)
            {
                Directory.Delete(folder, true);
                throw;
            }
            // An archive holding a single folder gives that folder, not a folder inside a folder.
            var entries = Directory.EnumerateFileSystemEntries(folder).ToList();
            if (entries.Count == 1 && Directory.Exists(entries[0]))
            {
                var inner = Output.Unique(Path.Combine(Path.GetDirectoryName(folder)!, Path.GetFileName(entries[0])));
                var temp = folder + ".adawat-tmp";
                Directory.Move(folder, temp);
                Directory.Move(Path.Combine(temp, Path.GetFileName(entries[0])), inner);
                Directory.Delete(temp, true);
                folder = inner;
            }
            outputs.Add(folder);
        }
        return outputs;
    }

    private static void ExtractTo(string file, string folder, OperationContext context)
    {
        Directory.CreateDirectory(folder);
        var ext = FileKinds.Ext(file);
        if (ext == "gz" && !Path.GetFileNameWithoutExtension(file).EndsWith(".tar", StringComparison.OrdinalIgnoreCase))
        {
            using var input = File.OpenRead(file);
            using var gzip = new GZipStream(input, CompressionMode.Decompress);
            using var output = File.Create(Path.Combine(folder, Path.GetFileNameWithoutExtension(file)));
            gzip.CopyToAsync(output, context.Cancellation).GetAwaiter().GetResult();
            return;
        }
        try
        {
            if (TarStream(file) is { } tar)
            {
                using (tar) ExtractTar(tar, folder, context);
                if (!Directory.EnumerateFileSystemEntries(folder).Any()) throw new AdawatException("The source archive is empty.");
                return;
            }
            using var archive = ArchiveFactory.Open(file, null);
            if (archive.IsSolid || archive.Type == ArchiveType.SevenZip || ext is "tgz")
            {
                using var reader = archive.ExtractAllEntries();
                while (reader.MoveToNextEntry())
                {
                    context.ThrowIfCancelled();
                    if (!reader.Entry.IsDirectory) reader.WriteEntryToDirectory(folder, new ExtractionOptions { ExtractFullPath = true, Overwrite = true });
                }
            }
            else
            {
                var entries = archive.Entries.Where(e => !e.IsDirectory).ToList();
                for (var index = 0; index < entries.Count; index++)
                {
                    context.Progress((double)index / Math.Max(1, entries.Count));
                    entries[index].WriteToDirectory(folder, new ExtractionOptions { ExtractFullPath = true, Overwrite = true });
                }
            }
            if (!Directory.EnumerateFileSystemEntries(folder).Any()) throw new AdawatException("The source archive is empty.");
        }
        // SharpCompress reports a file that is no archive at all as an InvalidOperationException; the tar reader reports
        // a damaged one as invalid data or a stream that ends early.
        catch (Exception e) when (e is CryptographicException or InvalidFormatException or SharpCompressException or InvalidOperationException
                                      or InvalidDataException or EndOfStreamException)
        {
            Directory.Delete(folder, true);
            throw new AdawatException("This archive is encrypted or uses a format Adawat cannot open.");
        }
    }

    /// <summary>The tar inside <paramref name="file"/>, decompressed as it is read, or null when the file is not a tar.</summary>
    private static Stream? TarStream(string file)
    {
        var name = Path.GetFileName(file).ToLowerInvariant();
        bool Ends(params string[] endings) => endings.Any(name.EndsWith);
        if (Ends(".tar")) return File.OpenRead(file);
        if (Ends(".tar.gz", ".tgz")) return new GZipStream(File.OpenRead(file), CompressionMode.Decompress);
        if (Ends(".tar.bz2", ".tbz", ".tbz2")) return new SharpCompress.Compressors.BZip2.BZip2Stream(File.OpenRead(file), SharpCompress.Compressors.CompressionMode.Decompress, false);
        if (Ends(".tar.xz", ".txz")) return new SharpCompress.Compressors.Xz.XZStream(File.OpenRead(file));
        return null;
    }

    /// <summary>
    /// Unpacks a tar with .NET's own reader. SharpCompress, which opens the other formats, takes the extended headers of
    /// a pax tar (the kind this app and bsdtar write) for files of their own, and does not look inside a compressed tar.
    /// Files and folders only: links and devices are left out, and nothing is written outside <paramref name="folder"/>.
    /// </summary>
    private static void ExtractTar(Stream stream, string folder, OperationContext context)
    {
        using var reader = new TarReader(stream);
        var root = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        while (reader.GetNextEntry() is { } entry)
        {
            context.ThrowIfCancelled();
            var target = Path.GetFullPath(Path.Combine(root, entry.Name.TrimStart('/', '\\')));
            if (!target.StartsWith(root, StringComparison.Ordinal)) continue;
            switch (entry.EntryType)
            {
                case TarEntryType.Directory:
                    Directory.CreateDirectory(target);
                    break;
                case TarEntryType.RegularFile or TarEntryType.V7RegularFile or TarEntryType.ContiguousFile:
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    entry.ExtractToFile(target, overwrite: true);
                    break;
            }
        }
    }

    /// <summary>Repacks an archive in another format: extract to a scratch folder, pack again.</summary>
    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, string format, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            using var temp = Output.Temp();
            var root = Path.Combine(temp.Path, "x");
            await Task.Run(() => ExtractTo(file, root, context));
            var items = Directory.EnumerateFileSystemEntries(root).ToList();
            var name = Path.GetFileNameWithoutExtension(file);
            if (name.EndsWith(".tar", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
            var output = Output.PathFor(file, format == "tgz" ? "tar.gz" : format);
            try
            {
                await Task.Run(() =>
                {
                    switch (format)
                    {
                        case "zip":
                            using (var zip = ZipFile.Open(output, ZipArchiveMode.Create)) foreach (var item in items) AddToZip(zip, item, Path.GetFileName(item), context);
                            break;
                        case "tar":
                            using (var stream = File.Create(output)) WriteTar(stream, items, context);
                            break;
                        default:
                            using (var stream = File.Create(output))
                            using (var gzip = new GZipStream(stream, CompressionLevel.Optimal)) WriteTar(gzip, items, context);
                            break;
                    }
                });
            }
            catch (OperationCanceledException)
            {
                File.Delete(output);
                throw;
            }
            outputs.Add(output);
        }
        return outputs;
    }
}
