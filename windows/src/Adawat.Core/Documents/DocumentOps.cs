using System.Text;

namespace Adawat.Core.Documents;

public enum DocumentTarget { Pdf, Docx, Epub, Md, Txt, Rtf, Html, Odt }

public static class DocumentTargets
{
    public static readonly IReadOnlyList<DocumentTarget> All =
        [DocumentTarget.Pdf, DocumentTarget.Docx, DocumentTarget.Epub, DocumentTarget.Md, DocumentTarget.Txt, DocumentTarget.Rtf, DocumentTarget.Html, DocumentTarget.Odt];

    public static string Ext(this DocumentTarget target) => target.ToString().ToLowerInvariant();

    public static string Title(this DocumentTarget target) => target == DocumentTarget.Md ? "MD" : target.ToString().ToUpperInvariant();
}

/// <summary>Conversions between text documents through <see cref="Doc"/>.</summary>
public static class DocumentOps
{
    public static async Task<Doc> Load(string path)
    {
        var title = Path.GetFileNameWithoutExtension(path);
        return FileKinds.Ext(path) switch
        {
            "docx" => await Task.Run(() => Docx.Read(path)),
            "doc" => await Office.WordToDoc(path),
            "md" or "markdown" => MarkdownFormat.Read(ReadText(path), title),
            "html" or "htm" => HtmlReader.Read(ReadText(path), title, src => LocalImage(path, src)),
            "epub" => await Task.Run(() => Epub.Read(path)),
            "odt" => await Task.Run(() => Odt.Read(path)),
            "rtf" => await Task.Run(() => Rtf.Read(path)),
            "pdf" => await Pdf.PdfOps.ReadDocument(path),
            "pages" => throw new AdawatException("Pages, Keynote and Numbers files are not supported on Windows."),
            _ => Doc.FromText(ReadText(path), title),
        };
    }

    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, DocumentTarget target, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.Report($"Converting {index + 1} of {files.Count}");
            context.Progress((double)index / files.Count);
            var file = files[index];
            var output = Output.PathFor(file, target.Ext());
            if (target == DocumentTarget.Pdf && await TryPrintWord(file, output))
            {
                outputs.Add(output);
                continue;
            }
            await Write(await Load(file), target, output);
            outputs.Add(output);
        }
        return outputs;
    }

    public static async Task Write(Doc doc, DocumentTarget target, string output)
    {
        switch (target)
        {
            case DocumentTarget.Pdf: await PdfPrinter.Print(DocText.Html(doc, forPrint: true), output); break;
            case DocumentTarget.Docx: await Task.Run(() => Docx.Write(doc, output)); break;
            case DocumentTarget.Epub: await Task.Run(() => Epub.Write(doc, output)); break;
            case DocumentTarget.Md: await File.WriteAllTextAsync(output, DocText.Markdown(doc), new UTF8Encoding(false)); break;
            case DocumentTarget.Txt: await File.WriteAllTextAsync(output, doc.PlainText, new UTF8Encoding(false)); break;
            case DocumentTarget.Rtf: await Task.Run(() => Rtf.Write(doc, output)); break;
            case DocumentTarget.Html: await File.WriteAllTextAsync(output, DocText.Html(doc), new UTF8Encoding(false)); break;
            case DocumentTarget.Odt: await Task.Run(() => Odt.Write(doc, output)); break;
        }
    }

    /// <summary>A Word document printed to PDF by Word or LibreOffice, which keep its letterhead and layout. False when
    /// neither is installed or the export failed, and the document then goes through <see cref="Doc"/> instead.</summary>
    private static async Task<bool> TryPrintWord(string file, string output)
    {
        if (!Office.CanPrintWord(FileKinds.Ext(file))) return false;
        try
        {
            await Office.WordToPdf(file, output);
            return File.Exists(output);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>Text in UTF-8, UTF-16 or, failing those, the Arabic Windows code page that older files use.</summary>
    public static string ReadText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length >= 2 && (bytes[0] == 0xFF && bytes[1] == 0xFE || bytes[0] == 0xFE && bytes[1] == 0xFF)) return Encoding.Unicode.GetString(bytes).TrimStart('﻿');
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿');
        }
        catch (DecoderFallbackException)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1256).GetString(bytes);
        }
    }

    private static (byte[] Data, string Ext)? LocalImage(string page, string src)
    {
        if (src.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return null;
        var path = Path.Combine(Path.GetDirectoryName(page) ?? "", src.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(path)) return null;
        var ext = FileKinds.Ext(path);
        return (File.ReadAllBytes(path), ext is "png" or "gif" ? ext : "jpg");
    }
}
