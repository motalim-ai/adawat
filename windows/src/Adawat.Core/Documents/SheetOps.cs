using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml.Linq;
using ClosedXML.Excel;
using ExcelDataReader;

namespace Adawat.Core.Documents;

/// <summary>A sheet as plain cells: text, or numbers kept as numbers.</summary>
public sealed record Sheet(string Name, List<List<object?>> Rows);

/// <summary>Spreadsheet conversions: Excel (xlsx and the older xls), OpenDocument, CSV and TSV in; Excel, OpenDocument,
/// CSV, TSV, PDF and HTML out.</summary>
public static class SheetOps
{
    public static readonly IReadOnlyList<string> Targets = ["xlsx", "ods", "csv", "tsv", "pdf", "html"];

    public static string Title(string target) => target.ToUpperInvariant();

    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, string target, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.ThrowIfCancelled();
            context.Report($"Converting {index + 1} of {files.Count}");
            var file = files[index];
            var sheets = await Task.Run(() => Read(file));
            if (sheets.Count == 0) throw new AdawatException($"{Path.GetFileName(file)} has no readable sheet.");
            var output = Output.PathFor(file, target);
            switch (target)
            {
                case "xlsx": await Task.Run(() => WriteXlsx(sheets, output)); break;
                case "ods": await Task.Run(() => WriteOds(sheets, output)); break;
                case "csv" or "tsv": await File.WriteAllTextAsync(output, Delimited(sheets[0], target == "csv" ? ',' : '\t'), new UTF8Encoding(true)); break;
                case "html": await File.WriteAllTextAsync(output, Html(sheets, Path.GetFileNameWithoutExtension(file), false), new UTF8Encoding(false)); break;
                case "pdf": await PdfPrinter.Print(Html(sheets, Path.GetFileNameWithoutExtension(file), true), output, landscape: sheets.Any(s => s.Rows.Any(r => r.Count > 6))); break;
            }
            outputs.Add(output);
        }
        return outputs;
    }

    // MARK: Reading

    public static List<Sheet> Read(string path) => FileKinds.Ext(path) switch
    {
        "xlsx" => ReadXlsx(path),
        "xls" => ReadXls(path),
        "ods" => ReadOds(path),
        "csv" => [ReadDelimited(path, ',')],
        "tsv" => [ReadDelimited(path, '\t')],
        "numbers" => throw new AdawatException("Pages, Keynote and Numbers files are not supported on Windows."),
        _ => throw new AdawatException($"{Path.GetFileName(path)} is not a spreadsheet."),
    };

    private static List<Sheet> ReadXlsx(string path)
    {
        using var book = new XLWorkbook(path);
        return book.Worksheets.Select(sheet =>
        {
            var used = sheet.RangeUsed();
            var rows = new List<List<object?>>();
            if (used != null)
            {
                foreach (var row in used.Rows())
                {
                    rows.Add(row.Cells().Select(cell => cell.Value.Type switch
                    {
                        XLDataType.Number => (object?)cell.Value.GetNumber(),
                        XLDataType.Boolean => cell.Value.GetBoolean(),
                        XLDataType.DateTime => cell.Value.GetDateTime(),
                        XLDataType.Blank => null,
                        _ => cell.GetFormattedString(),
                    }).ToList());
                }
            }
            return new Sheet(sheet.Name, rows);
        }).ToList();
    }

    private static List<Sheet> ReadXls(string path)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        using var stream = File.OpenRead(path);
        using var reader = ExcelReaderFactory.CreateReader(stream);
        var sheets = new List<Sheet>();
        do
        {
            var rows = new List<List<object?>>();
            while (reader.Read())
            {
                var row = new List<object?>();
                for (var c = 0; c < reader.FieldCount; c++) row.Add(reader.GetValue(c));
                rows.Add(row);
            }
            sheets.Add(new Sheet(reader.Name ?? $"Sheet{sheets.Count + 1}", rows));
        } while (reader.NextResult());
        return sheets;
    }

    private static readonly XNamespace OfficeNs = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    private static readonly XNamespace TableNs = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    private static readonly XNamespace TextNs = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

    private static List<Sheet> ReadOds(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var content = XDocument.Load(zip.GetEntry("content.xml")!.Open());
        return content.Descendants(TableNs + "table").Select(table =>
        {
            var rows = new List<List<object?>>();
            foreach (var row in table.Elements(TableNs + "table-row"))
            {
                var repeatRows = Math.Min(int.TryParse(row.Attribute(TableNs + "number-rows-repeated")?.Value, out var rr) ? rr : 1, 1000);
                var cells = new List<object?>();
                foreach (var cell in row.Elements().Where(e => e.Name.LocalName is "table-cell" or "covered-table-cell"))
                {
                    var repeat = Math.Min(int.TryParse(cell.Attribute(TableNs + "number-columns-repeated")?.Value, out var r) ? r : 1, 1000);
                    object? value = cell.Attribute(OfficeNs + "value-type")?.Value switch
                    {
                        "float" or "percentage" or "currency" => double.TryParse(cell.Attribute(OfficeNs + "value")?.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null,
                        "boolean" => cell.Attribute(OfficeNs + "boolean-value")?.Value == "true",
                        null => null,
                        _ => string.Join("\n", cell.Elements(TextNs + "p").Select(p => p.Value)),
                    };
                    for (var i = 0; i < repeat; i++) cells.Add(value);
                }
                while (cells.Count > 0 && cells[^1] == null) cells.RemoveAt(cells.Count - 1);
                for (var i = 0; i < repeatRows; i++) rows.Add(cells);
            }
            while (rows.Count > 0 && rows[^1].Count == 0) rows.RemoveAt(rows.Count - 1);
            return new Sheet(table.Attribute(TableNs + "name")?.Value ?? "Sheet1", rows);
        }).ToList();
    }

    private static Sheet ReadDelimited(string path, char separator)
    {
        var text = DocumentOps.ReadText(path);
        // Spreadsheets saved in Europe often separate with semicolons.
        if (separator == ',' && text.Count(c => c == ';') > text.Count(c => c == ',') * 2) separator = ';';
        var rows = new List<List<object?>>();
        var row = new List<object?>();
        var field = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c == '"' && i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else if (c == '"') quoted = false;
                else field.Append(c);
                continue;
            }
            if (c == '"' && field.Length == 0) quoted = true;
            else if (c == separator) { row.Add(Typed(field.ToString())); field.Clear(); }
            else if (c is '\n' or '\r')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(Typed(field.ToString()));
                field.Clear();
                rows.Add(row);
                row = [];
            }
            else field.Append(c);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(Typed(field.ToString())); rows.Add(row); }
        return new Sheet(Path.GetFileNameWithoutExtension(path), rows);
    }

    private static object? Typed(string text)
    {
        if (text.Length == 0) return null;
        if (text.Length < 16 && !text.StartsWith('0') || text == "0" || text.StartsWith("0."))
        {
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)) return number;
        }
        return text;
    }

    // MARK: Writing

    private static void WriteXlsx(List<Sheet> sheets, string path)
    {
        using var book = new XLWorkbook();
        foreach (var sheet in sheets)
        {
            var name = new string(sheet.Name.Where(c => !"[]*?/\\:".Contains(c)).ToArray());
            if (name.Length == 0) name = $"Sheet{book.Worksheets.Count + 1}";
            if (name.Length > 31) name = name[..31];
            while (book.Worksheets.Contains(name)) name = name[..Math.Min(name.Length, 28)] + book.Worksheets.Count;
            var ws = book.Worksheets.Add(name);
            for (var r = 0; r < sheet.Rows.Count; r++)
            for (var c = 0; c < sheet.Rows[r].Count; c++)
            {
                var cell = ws.Cell(r + 1, c + 1);
                switch (sheet.Rows[r][c])
                {
                    case double d: cell.Value = d; break;
                    case int i: cell.Value = i; break;
                    case bool b: cell.Value = b; break;
                    case DateTime t: cell.Value = t; break;
                    case null: break;
                    case var other: cell.Value = other.ToString(); break;
                }
            }
            if (sheet.Rows.SelectMany(r => r).OfType<string>().Any(Bidi.IsRightToLeft)) ws.RightToLeft = true;
            ws.Columns().AdjustToContents(1, Math.Min(200, sheet.Rows.Count));
        }
        book.SaveAs(path);
    }

    private static void WriteOds(List<Sheet> sheets, string path)
    {
        var body = new XElement(OfficeNs + "spreadsheet", sheets.Select(sheet => new XElement(TableNs + "table", new XAttribute(TableNs + "name", sheet.Name),
            sheet.Rows.Select(row => new XElement(TableNs + "table-row", row.Select(value => value switch
            {
                double d => new XElement(TableNs + "table-cell", new XAttribute(OfficeNs + "value-type", "float"), new XAttribute(OfficeNs + "value", d.ToString(CultureInfo.InvariantCulture)),
                                         new XElement(TextNs + "p", d.ToString(CultureInfo.InvariantCulture))),
                null => new XElement(TableNs + "table-cell"),
                _ => new XElement(TableNs + "table-cell", new XAttribute(OfficeNs + "value-type", "string"), new XElement(TextNs + "p", value.ToString())),
            }))))));
        var content = new XDocument(new XElement(OfficeNs + "document-content",
            new XAttribute(XNamespace.Xmlns + "office", OfficeNs), new XAttribute(XNamespace.Xmlns + "table", TableNs), new XAttribute(XNamespace.Xmlns + "text", TextNs),
            new XAttribute(OfficeNs + "version", "1.3"), new XElement(OfficeNs + "body", body)));
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        using (var mimetype = new StreamWriter(zip.CreateEntry("mimetype", CompressionLevel.NoCompression).Open())) mimetype.Write("application/vnd.oasis.opendocument.spreadsheet");
        using (var stream = zip.CreateEntry("content.xml").Open()) content.Save(stream);
        using var manifest = new StreamWriter(zip.CreateEntry("META-INF/manifest.xml").Open());
        manifest.Write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
             <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
             <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
            </manifest:manifest>
            """);
    }

    private static string Delimited(Sheet sheet, char separator)
    {
        var text = new StringBuilder();
        foreach (var row in sheet.Rows)
        {
            text.AppendJoin(separator, row.Select(value =>
            {
                var s = value switch { double d => d.ToString(CultureInfo.InvariantCulture), null => "", _ => value.ToString() ?? "" };
                return s.IndexOfAny([separator, '"', '\n', '\r']) >= 0 ? $"\"{s.Replace("\"", "\"\"")}\"" : s;
            }));
            text.Append("\r\n");
        }
        return text.ToString();
    }

    private static string Html(List<Sheet> sheets, string title, bool forPrint)
    {
        var rtl = sheets.SelectMany(s => s.Rows).SelectMany(r => r).OfType<string>().Any(Bidi.IsRightToLeft);
        var html = new StringBuilder($"<!DOCTYPE html><html dir=\"{(rtl ? "rtl" : "ltr")}\"><head><meta charset=\"utf-8\"><title>{DocText.Escape(title)}</title><style>");
        html.Append(forPrint ? "@page { margin: 0.5in; } " : "");
        html.Append("body { font-family: 'Segoe UI', Arial, sans-serif; font-size: 10pt; } h2 { font-size: 12pt; margin: 1em 0 0.4em; } ");
        html.Append("table { border-collapse: collapse; margin-bottom: 1.5em; } td { border: 1px solid #c8c8cc; padding: 3px 6px; white-space: nowrap; } ");
        html.Append("td.n { text-align: end; font-variant-numeric: tabular-nums; } tr:first-child td { background: #f1f1f4; font-weight: 600; } .break { page-break-after: always; }");
        html.Append("</style></head><body>");
        for (var s = 0; s < sheets.Count; s++)
        {
            if (sheets.Count > 1) html.Append($"<h2>{DocText.Escape(sheets[s].Name)}</h2>");
            html.Append("<table>");
            foreach (var row in sheets[s].Rows)
                html.Append("<tr>").Append(string.Concat(row.Select(v => v is double d ? $"<td class=\"n\">{d.ToString(CultureInfo.CurrentCulture)}</td>" : $"<td>{DocText.Escape(v?.ToString() ?? "")}</td>"))).Append("</tr>");
            html.Append("</table>");
            if (forPrint && s < sheets.Count - 1) html.Append("<div class=\"break\"></div>");
        }
        return html.Append("</body></html>").ToString();
    }
}
