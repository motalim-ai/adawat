using System.Formats.Tar;
using System.IO.Compression;

namespace Adawat.Core.Tests;

public class ArchiveTests
{
    /// <summary>A folder with a few files and a folder inside, and what it holds as "relative path = text".</summary>
    private static string Folder(Scratch scratch, string name = "trip")
    {
        var folder = Directory.CreateDirectory(scratch.File(name)).FullName;
        File.WriteAllText(Path.Combine(folder, "notes.txt"), "packing list");
        File.WriteAllText(Path.Combine(folder, "عربي.txt"), "مرحبا");
        Directory.CreateDirectory(Path.Combine(folder, "photos"));
        File.WriteAllBytes(Path.Combine(folder, "photos", "one.bin"), Enumerable.Range(0, 5000).Select(n => (byte)(n * 7)).ToArray());
        return folder;
    }

    private static List<string> Contents(string folder) => Directory.GetFiles(folder, "*", SearchOption.AllDirectories)
        .Select(file => $"{Path.GetRelativePath(folder, file).Replace('\\', '/')} = {Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(file)))[..12]}")
        .OrderBy(line => line, StringComparer.Ordinal).ToList();

    [Theory]
    [InlineData("zip", "trip.zip")]
    [InlineData("tar", "trip.tar")]
    [InlineData("tgz", "trip.tar.gz")]
    public async Task AFolderPacksAndComesBackTheSame(string format, string name)
    {
        using var scratch = new Scratch();
        var folder = Folder(scratch);
        var archive = await TestKit.RunOne($"archive.{format}", folder);
        Assert.Equal(scratch.File(name), archive);
        var extracted = await TestKit.RunOne("archive.extract", archive);
        Assert.NotEqual(folder, extracted);
        Assert.Equal(Contents(folder), Contents(extracted));
    }

    [Fact]
    public async Task SeveralFilesPackIntoOneArchive()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("a.txt"), "first");
        File.WriteAllText(scratch.File("b.xyz"), "second");
        var archive = await TestKit.RunOne("archive.zip", scratch.File("a.txt"), scratch.File("b.xyz"));
        var extracted = await TestKit.RunOne("archive.extract", archive);
        Assert.Equal(["a.txt", "b.xyz"], Directory.GetFiles(extracted).Select(Path.GetFileName).Order());
    }

    [Fact]
    public async Task AZipBecomesATarWithTheSameFiles()
    {
        using var scratch = new Scratch();
        var folder = Folder(scratch);
        var zip = await TestKit.RunOne("archive.zip", folder);
        var tar = await TestKit.RunOne("archive.to-tar", zip);
        Assert.EndsWith(".tar", tar);
        var extracted = await TestKit.RunOne("archive.extract", tar);
        Assert.Equal(Contents(folder), Contents(extracted));
    }

    /// <summary>Tars from other tools: the old GNU kind, and one squeezed with bzip2.</summary>
    [Theory]
    [InlineData("gnu.tar")]
    [InlineData("gnu.tar.gz")]
    [InlineData("gnu.tar.bz2")]
    public async Task ATarMadeElsewhereExtracts(string name)
    {
        using var scratch = new Scratch();
        var folder = Folder(scratch);
        var archive = scratch.File(name);
        using (var file = File.Create(archive))
        using (Stream packed = name.EndsWith(".gz") ? new GZipStream(file, CompressionLevel.Fastest)
                             : name.EndsWith(".bz2") ? new SharpCompress.Compressors.BZip2.BZip2Stream(file, SharpCompress.Compressors.CompressionMode.Compress, false)
                             : file)
        using (var tar = new TarWriter(packed, TarEntryFormat.Gnu, leaveOpen: true))
        {
            foreach (var path in Directory.GetFiles(folder, "*", SearchOption.AllDirectories))
                tar.WriteEntry(path, "trip/" + Path.GetRelativePath(folder, path).Replace('\\', '/'));
        }
        var extracted = await TestKit.RunOne("archive.extract", archive);
        Assert.Equal(Contents(folder), Contents(extracted));
    }

    [Fact]
    public async Task ATarCannotWriteOutsideItsFolder()
    {
        using var scratch = new Scratch();
        var inside = Directory.CreateDirectory(scratch.File("inside")).FullName;
        var archive = Path.Combine(inside, "sly.tar");
        using (var file = File.Create(archive))
        using (var tar = new TarWriter(file, TarEntryFormat.Pax))
        {
            tar.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "../escaped.txt") { DataStream = new MemoryStream("out"u8.ToArray()) });
            tar.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "/rooted.txt") { DataStream = new MemoryStream("in"u8.ToArray()) });
            tar.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "fine.txt") { DataStream = new MemoryStream("in"u8.ToArray()) });
        }
        var extracted = await TestKit.RunOne("archive.extract", archive);
        Assert.Equal(["inside/"], scratch.Names());
        Assert.Equal(["fine.txt", "rooted.txt"], Directory.GetFiles(extracted, "*", SearchOption.AllDirectories).Select(Path.GetFileName).Order());
    }

    [Fact]
    public async Task ASingleFileGzipsAndComesBack()
    {
        using var scratch = new Scratch();
        var file = scratch.File("data.xyz");
        File.WriteAllText(file, string.Concat(Enumerable.Repeat("squeeze me ", 500)));
        var gz = await TestKit.RunOne("archive.gz", file);
        Assert.Equal(scratch.File("data.xyz.gz"), gz);
        Assert.True(new FileInfo(gz).Length < new FileInfo(file).Length);
        var extracted = await TestKit.RunOne("archive.extract", gz);
        var inside = Directory.Exists(extracted) ? Directory.GetFiles(extracted).Single() : extracted;
        Assert.Equal(File.ReadAllText(file), File.ReadAllText(inside));
    }

    [Fact]
    public async Task AFileThatIsNotAnArchiveIsReportedInWords()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("fake.zip"), "not a zip at all");
        await Assert.ThrowsAsync<AdawatException>(() => TestKit.Run("archive.extract", scratch.File("fake.zip")));
        Assert.Equal(["fake.zip"], scratch.Names());
    }
}
