using System.Text;
using Adawat.Core.Documents;
using Adawat.Core.Images;
using ClosedXML.Excel;
using ImageMagick;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using System.Numerics;
using UglyToad.PdfPig.Content;
using Pig = UglyToad.PdfPig;

namespace Adawat.Core.Pdf;

/// <summary>One page slot in the organizer: which source page it shows and how far it is turned.</summary>
public sealed record PageSlot(int Source, int Rotation = 0)
{
    public Guid Id { get; } = Guid.NewGuid();
}

/// <summary>Everything Adawat does with PDFs: text (read or recognised), pages as pictures, compression, merging,
/// splitting, organizing, and conversion to documents and spreadsheets.</summary>
public static class PdfOps
{
    // MARK: Pages as pictures

    public static int PageCount(string path)
    {
        using var stream = File.OpenRead(path);
        return PDFtoImage.Conversion.GetPageCount(stream);
    }

    /// <summary>One page as a picture at <paramref name="dpi"/>, white behind transparent areas.</summary>
    public static MagickImage RenderPage(string path, int page, int dpi = 150)
    {
        using var stream = File.OpenRead(path);
        using var bitmap = PDFtoImage.Conversion.ToImage(stream, page: page, leaveOpen: false,
            options: new PDFtoImage.RenderOptions(Dpi: dpi, WithAnnotations: true, WithFormFill: true, BackgroundColor: SkiaSharp.SKColors.White));
        using var data = bitmap.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
        return new MagickImage(data.ToArray());
    }

    public static async Task<IReadOnlyList<string>> RenderPages(IReadOnlyList<string> files, ImageFormat format, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var count = PageCount(file);
            var folder = count > 1 ? Output.Named($"{Path.GetFileNameWithoutExtension(file)} pages", file) : null;
            if (folder != null) Directory.CreateDirectory(folder);
            for (var page = 0; page < count; page++)
            {
                context.Report($"Rendering page {page + 1} of {count}");
                context.Progress((double)page / count);
                var output = folder != null ? Path.Combine(folder, $"Page {page + 1}.{format.Ext}") : Output.PathFor(file, format.Ext);
                await Task.Run(() =>
                {
                    using var image = RenderPage(file, page, 300);
                    ImageEngine.Save(image, format, output, 0.9);
                });
                if (folder == null) outputs.Add(output);
            }
            if (folder != null) outputs.Add(folder);
        }
        return outputs;
    }

    // MARK: Text

    /// <summary>The text of every page: the PDF's own text where it has some, recognised from the page picture where it does not.</summary>
    public static async Task<string> Text(string path, OperationContext context)
    {
        var pages = new List<string>();
        var count = PageCount(path);
        using var pdf = Pig.PdfDocument.Open(path);
        for (var index = 0; index < count; index++)
        {
            context.Progress((double)index / count);
            var page = pdf.GetPage(index + 1);
            var text = string.Join("\n", Lines(page).Select(line => line.Text));
            if (text.Count(char.IsLetterOrDigit) < 20)
            {
                context.Report($"Recognizing page {index + 1} of {count}");
                using var image = await Task.Run(() => RenderPage(path, index, 200));
                text = await Recognition.Text(image);
            }
            pages.Add(text.Trim());
        }
        return string.Join("\n\n", pages.Where(p => p.Length > 0));
    }

    public static async Task<IReadOnlyList<string>> ToText(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var output = Output.PathFor(file, "txt");
            await File.WriteAllTextAsync(output, await Text(file, context), new UTF8Encoding(false));
            outputs.Add(output);
        }
        return outputs;
    }

    internal sealed record TextLine(string Text, double Top, double Bottom, double Left, double Right, double FontSize, bool Bold, List<Word> Words);

    /// <summary>Lines of a page in reading order, with Arabic put back into logical order: PDFs store it as drawn, right to left.</summary>
    internal static List<TextLine> Lines(Page page)
    {
        var words = page.GetWords(UglyToad.PdfPig.DocumentLayoutAnalysis.WordExtractor.NearestNeighbourWordExtractor.Instance).Where(w => w.Text.Trim().Length > 0).ToList();
        var lines = new List<List<Word>>();
        foreach (var word in words.OrderByDescending(w => w.BoundingBox.Bottom))
        {
            var height = Math.Max(1, word.BoundingBox.Height);
            var line = lines.FirstOrDefault(l => Math.Abs(l[0].BoundingBox.Bottom - word.BoundingBox.Bottom) < height * 0.5);
            if (line != null) line.Add(word); else lines.Add([word]);
        }
        return lines.Select(line =>
        {
            var rtl = line.Sum(w => w.Text.Count(IsArabic)) > line.Sum(w => w.Text.Count(char.IsLetter)) / 2;
            var ordered = rtl ? line.OrderByDescending(w => w.BoundingBox.Left).ToList() : line.OrderBy(w => w.BoundingBox.Left).ToList();
            var text = string.Join(" ", ordered.Select(w => Logical(w)));
            var letters = line.SelectMany(w => w.Letters).ToList();
            var size = letters.Count > 0 ? letters.Average(l => l.PointSize) : 10;
            var bold = letters.Count > 0 && letters.Count(l => l.FontName?.Contains("Bold", StringComparison.OrdinalIgnoreCase) == true) > letters.Count / 2;
            return new TextLine(text, line.Max(w => w.BoundingBox.Top), line.Min(w => w.BoundingBox.Bottom), line.Min(w => w.BoundingBox.Left),
                                line.Max(w => w.BoundingBox.Right), size, bold, ordered);
        }).OrderByDescending(l => l.Top).ToList();
    }

    private static bool IsArabic(char c) => c is >= '؀' and <= 'ۿ' or >= 'ݐ' and <= 'ݿ' or >= 'ﭐ' and <= '﷿' or >= 'ﹰ' and <= '﻿';

    /// <summary>A word's letters in logical order, with Arabic presentation forms folded back into ordinary letters.</summary>
    private static string Logical(Word word)
    {
        var text = word.Text;
        if (!text.Any(IsArabic)) return text;
        var letters = word.Letters.Where(l => l.Value.Length > 0).ToList();
        if (letters.Count > 1 && letters[0].StartBaseLine.X < letters[^1].StartBaseLine.X)
            text = string.Concat(letters.OrderByDescending(l => l.StartBaseLine.X).Select(l => l.Value));
        return text.Normalize(NormalizationForm.FormKC);
    }

    // MARK: Documents

    /// <summary>A PDF as a document: paragraphs from the text layout, headings from larger type, pictures, and a page break between pages.
    /// Scanned pages are recognised.</summary>
    public static async Task<Doc> ReadDocument(string path)
    {
        var doc = new Doc { Title = Path.GetFileNameWithoutExtension(path) };
        using var pdf = Pig.PdfDocument.Open(path);
        var allSizes = pdf.GetPages().SelectMany(p => p.Letters.Select(l => l.PointSize)).Where(s => s > 0).OrderBy(s => s).ToList();
        var body = allSizes.Count > 0 ? allSizes[allSizes.Count / 2] : 10;
        for (var index = 1; index <= pdf.NumberOfPages; index++)
        {
            if (index > 1) doc.Blocks.Add(new PageBreak());
            var page = pdf.GetPage(index);
            var lines = Lines(page);
            if (lines.Sum(l => l.Text.Count(char.IsLetterOrDigit)) < 20)
            {
                using var image = await Task.Run(() => RenderPage(path, index - 1, 200));
                var recognised = await Recognition.Text(image);
                foreach (var para in recognised.Split("\n\n")) if (para.Trim().Length > 0) doc.Blocks.Add(new Documents.Paragraph([new Span(para.Trim())]));
                continue;
            }
            var paragraph = new List<TextLine>();
            void Flush()
            {
                if (paragraph.Count == 0) return;
                var text = string.Join(" ", paragraph.Select(l => l.Text));
                var size = paragraph.Average(l => l.FontSize);
                var bold = paragraph.All(l => l.Bold);
                if (size > body * 1.6 && text.Length < 160) doc.Blocks.Add(new Heading(1, [new Span(text)]));
                else if (size > body * 1.25 && text.Length < 160) doc.Blocks.Add(new Heading(2, [new Span(text)]));
                else if (bold && text.Length < 100 && paragraph.Count == 1) doc.Blocks.Add(new Heading(3, [new Span(text)]));
                else if (text.TrimStart().StartsWith("•") || text.TrimStart().StartsWith("- ")) doc.Blocks.Add(new ListItem([new Span(text.TrimStart('•', '-', ' '))], false));
                else doc.Blocks.Add(new Documents.Paragraph([new Span(text)]));
                paragraph.Clear();
            }
            for (var i = 0; i < lines.Count; i++)
            {
                var line = lines[i];
                if (paragraph.Count > 0)
                {
                    var previous = paragraph[^1];
                    var gap = previous.Bottom - line.Top;
                    var lineHeight = Math.Max(1, previous.Top - previous.Bottom);
                    var newBlock = gap > lineHeight * 0.9 || Math.Abs(line.FontSize - previous.FontSize) > 1.5 || previous.Bold != line.Bold
                                   || line.Text.TrimStart().StartsWith("•");
                    if (newBlock) Flush();
                }
                paragraph.Add(line);
            }
            Flush();
            foreach (var picture in page.GetImages())
            {
                if (picture.BoundingBox.Width < 40 || picture.BoundingBox.Height < 40) continue;
                if (picture.TryGetPng(out var png)) doc.Blocks.Add(new Picture(png, "png"));
                else
                {
                    var raw = picture.RawBytes.ToArray();
                    if (raw.Length > 2 && raw[0] == 0xFF && raw[1] == 0xD8) doc.Blocks.Add(new Picture(raw, "jpg"));
                }
            }
        }
        return doc;
    }

    public static async Task<IReadOnlyList<string>> ToDocument(IReadOnlyList<string> files, DocumentTarget target, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.Report($"Converting {index + 1} of {files.Count}");
            var file = files[index];
            var output = Output.PathFor(file, target.Ext());
            await DocumentOps.Write(await ReadDocument(file), target, output);
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>Tables on each page become a sheet: text lines are rows, and wide gaps between words split the cells.</summary>
    public static async Task<IReadOnlyList<string>> ToExcel(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var output = Output.PathFor(file, "xlsx");
            await Task.Run(() =>
            {
                using var pdf = Pig.PdfDocument.Open(file);
                using var book = new XLWorkbook();
                for (var index = 1; index <= pdf.NumberOfPages; index++)
                {
                    context.Report($"Page {index} of {pdf.NumberOfPages}");
                    var sheet = book.Worksheets.Add($"Page {index}");
                    var lines = Lines(pdf.GetPage(index));
                    // Column edges shared by the page: the left edges where cells start, clustered.
                    var rtl = lines.Sum(l => l.Text.Count(IsArabic)) > lines.Sum(l => l.Text.Length) / 3;
                    if (rtl) sheet.RightToLeft = true;
                    var row = 1;
                    foreach (var line in lines)
                    {
                        var cells = Cells(line, rtl);
                        for (var c = 0; c < cells.Count; c++)
                        {
                            var value = cells[c];
                            var cell = sheet.Cell(row, c + 1);
                            if (double.TryParse(value.Replace(",", ""), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) && !value.StartsWith('0'))
                                cell.Value = number;
                            else
                                cell.Value = value;
                        }
                        row++;
                    }
                    sheet.Columns().AdjustToContents(1, 200);
                }
                if (book.Worksheets.Count == 0) book.Worksheets.Add("Page 1");
                book.SaveAs(output);
            });
            outputs.Add(output);
        }
        return outputs;
    }

    private static List<string> Cells(TextLine line, bool rtl)
    {
        var words = line.Words;
        if (words.Count == 0) return [];
        var averageChar = words.Average(w => w.BoundingBox.Width / Math.Max(1, w.Text.Length));
        var cells = new List<List<Word>> { new() { words[0] } };
        for (var i = 1; i < words.Count; i++)
        {
            var gap = rtl ? words[i - 1].BoundingBox.Left - words[i].BoundingBox.Right : words[i].BoundingBox.Left - words[i - 1].BoundingBox.Right;
            if (gap > averageChar * 2.2) cells.Add([words[i]]); else cells[^1].Add(words[i]);
        }
        return cells.Select(cell => string.Join(" ", cell.Select(Logical))).ToList();
    }

    // MARK: Editing with PDFsharp

    private static PdfDocument Open(string path, PdfDocumentOpenMode mode)
    {
        try { return PdfReader.Open(path, mode); }
        catch (PdfReaderException) { throw new AdawatException($"{Path.GetFileName(path)} cannot be read or is password-protected"); }
        catch (InvalidOperationException) { throw new AdawatException($"{Path.GetFileName(path)} cannot be read or is password-protected"); }
    }

    public static async Task<IReadOnlyList<string>> Merge(IReadOnlyList<string> files, OperationContext context)
    {
        var output = Output.Named($"{Path.GetFileNameWithoutExtension(files[0])} merged.pdf", files[0]);
        var pages = 0;
        await Task.Run(() =>
        {
            using var merged = new PdfDocument();
            merged.Info.Creator = "Adawat";
            for (var index = 0; index < files.Count; index++)
            {
                context.Progress((double)index / files.Count);
                using var source = Open(files[index], PdfDocumentOpenMode.Import);
                foreach (var page in source.Pages) { merged.AddPage(page); pages++; }
            }
            merged.Save(output);
        });
        context.Finish($"Merged {files.Count} PDFs · {pages} pages");
        return [output];
    }

    public static async Task<IReadOnlyList<string>> Split(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var folder = Output.Named($"{Path.GetFileNameWithoutExtension(file)} pages", file);
            await Task.Run(() =>
            {
                using var source = Open(file, PdfDocumentOpenMode.Import);
                if (source.PageCount < 2) throw new AdawatException($"{Path.GetFileName(file)} has no pages");
                Directory.CreateDirectory(folder);
                for (var index = 0; index < source.PageCount; index++)
                {
                    context.Progress((double)index / source.PageCount);
                    using var single = new PdfDocument();
                    single.AddPage(source.Pages[index]);
                    single.Save(Path.Combine(folder, $"Page {index + 1}.pdf"));
                }
            });
            outputs.Add(folder);
        }
        return outputs;
    }

    public static async Task<IReadOnlyList<string>> StripMetadata(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var output = Output.PathFor(file, "pdf", "clean");
            await Task.Run(() =>
            {
                using var pdf = Open(file, PdfDocumentOpenMode.Modify);
                pdf.Info.Elements.Clear();
                pdf.Internals.Catalog.Elements.Remove("/Metadata");
                foreach (var page in pdf.Pages) page.Elements.Remove("/Metadata");
                pdf.Options.CompressContentStreams = true;
                pdf.Save(output);
            });
            outputs.Add(output);
        }
        context.Finish(files.Count == 1 ? "Metadata removed from 1 PDF" : $"Metadata removed from {files.Count} PDFs");
        return outputs;
    }

    /// <summary>Re-encodes the pictures inside each PDF smaller (text and vectors stay as they are) and compresses every stream.
    /// Each picture keeps enough pixels for the size the page shows it at, so a photo shown small loses only pixels nobody sees.</summary>
    public static async Task<IReadOnlyList<string>> Compress(IReadOnlyList<string> files, OperationContext context)
    {
        var preset = Settings.Current.CompressPreset;
        // dpi: pixels kept per inch the picture covers on the page; maxPixels: the most any picture keeps on its longest side.
        var (dpi, maxPixels, quality) = preset switch { CompressPreset.Light => (220, 2400, 82), CompressPreset.Balanced => (150, 1800, 68), _ => (110, 1300, 55) };
        var outputs = new List<string>();
        long before = 0, after = 0;
        foreach (var file in files)
        {
            var output = Output.PathFor(file, "pdf", "compressed");
            await Task.Run(() =>
            {
                using var pdf = Open(file, PdfDocumentOpenMode.Modify);
                var seen = new HashSet<PdfDictionary>();
                var shown = new Dictionary<PdfDictionary, double>();
                foreach (var page in pdf.Pages) Measure(ContentReader.ReadContent(page), page.Elements.GetDictionary("/Resources"), Matrix3x2.Identity, shown, 0);
                for (var index = 0; index < pdf.PageCount; index++)
                {
                    context.Progress((double)index / pdf.PageCount);
                    foreach (var image in Images(pdf.Pages[index].Elements.GetDictionary("/Resources"), seen))
                        // Pictures under 800 pixels, such as logos, stay sharp: they cost little and the text in them blurs first.
                        Recompress(image, shown.TryGetValue(image, out var inches) ? (int)Math.Ceiling(Math.Clamp(inches * dpi, 800, maxPixels)) : maxPixels, quality);
                }
                pdf.Options.CompressContentStreams = true;
                pdf.Options.NoCompression = false;
                pdf.Options.FlateEncodeMode = PdfFlateEncodeMode.BestCompression;
                pdf.Options.UseFlateDecoderForJpegImages = PdfUseFlateDecoderForJpegImages.Never;
                pdf.Save(output);
            });
            var original = new FileInfo(file).Length;
            if (new FileInfo(output).Length >= original)
            {
                File.Delete(output);
                continue;
            }
            before += original;
            after += new FileInfo(output).Length;
            outputs.Add(output);
        }
        if (outputs.Count == 0) throw new AdawatException("These PDFs are already as small as they get");
        context.Finish(outputs.Count == 1 ? $"Compressed PDF · {Math.Min(99, 100 - (int)Math.Round((double)after / before * 100))}% smaller"
                                          : Compression.Savings("PDF", outputs.Count, before, after));
        return outputs;
    }

    private static IEnumerable<PdfDictionary> Images(PdfDictionary? resources, HashSet<PdfDictionary> seen)
    {
        var objects = resources?.Elements.GetDictionary("/XObject");
        if (objects == null) yield break;
        foreach (var key in objects.Elements.Keys)
        {
            if (objects.Elements.GetReference(key)?.Value is not PdfDictionary item || !seen.Add(item)) continue;
            var subtype = item.Elements.GetName("/Subtype");
            if (subtype == "/Image") yield return item;
            else if (subtype == "/Form")
            {
                foreach (var image in Images(item.Elements.GetDictionary("/Resources"), seen)) yield return image;
            }
        }
    }

    /// <summary>Records, for every picture the content draws, the longest side in inches it is ever shown at.</summary>
    private static void Measure(CSequence content, PdfDictionary? resources, Matrix3x2 matrix, Dictionary<PdfDictionary, double> shown, int depth)
    {
        var objects = resources?.Elements.GetDictionary("/XObject");
        var saved = new Stack<Matrix3x2>();
        foreach (var item in content)
        {
            if (item is not COperator op) continue;
            switch (op.OpCode.OpCodeName)
            {
                case OpCodeName.q: saved.Push(matrix); break;
                case OpCodeName.Q: if (saved.Count > 0) matrix = saved.Pop(); break;
                case OpCodeName.cm when op.Operands.Count == 6: matrix = Matrix(op.Operands) * matrix; break;
                case OpCodeName.Do when op.Operands.Count == 1 && op.Operands[0] is CName name:
                    if (objects?.Elements.GetReference(name.Name)?.Value is not PdfDictionary target) break;
                    if (target.Elements.GetName("/Subtype") == "/Image")
                    {
                        // The picture fills the unit square, so the matrix's two axes are its drawn width and height. A stretched
                        // picture keeps the pixels its denser side needs, given as inches along its longest side.
                        var x = new Vector2(matrix.M11, matrix.M12).Length() / 72;
                        var y = new Vector2(matrix.M21, matrix.M22).Length() / 72;
                        var width = Math.Max(target.Elements.GetInteger("/Width"), 1);
                        var height = Math.Max(target.Elements.GetInteger("/Height"), 1);
                        shown[target] = Math.Max(shown.GetValueOrDefault(target), Math.Max(x / width, y / height) * Math.Max(width, height));
                    }
                    else if (target.Elements.GetName("/Subtype") == "/Form" && depth < 8 && target.Stream != null)
                    {
                        var form = target.Elements.GetArray("/Matrix") is { Elements.Count: 6 } m
                            ? new Matrix3x2((float)Number(m.Elements[0]), (float)Number(m.Elements[1]), (float)Number(m.Elements[2]),
                                            (float)Number(m.Elements[3]), (float)Number(m.Elements[4]), (float)Number(m.Elements[5]))
                            : Matrix3x2.Identity;
                        Measure(ContentReader.ReadContent(target.Stream.UnfilteredValue), target.Elements.GetDictionary("/Resources") ?? resources,
                                form * matrix, shown, depth + 1);
                    }
                    break;
            }
        }
    }

    private static Matrix3x2 Matrix(CSequence operands) => new(Operand(operands[0]), Operand(operands[1]), Operand(operands[2]),
                                                               Operand(operands[3]), Operand(operands[4]), Operand(operands[5]));

    private static float Operand(CObject value) => value switch { CReal real => (float)real.Value, CInteger integer => integer.Value, _ => 0 };

    private static double Number(PdfItem item) => item switch { PdfReal real => real.Value, PdfInteger integer => integer.Value, _ => 0 };

    /// <summary>"/DCTDecode" also for a one-filter array, as many PDF writers store it.</summary>
    private static string Single(PdfItem? item) => item is PdfArray { Elements.Count: 1 } array ? array.Elements[0].ToString()! : item?.ToString() ?? "";

    private static void Recompress(PdfDictionary image, int maxPixels, int quality)
    {
        if (image.Stream == null || image.Elements.ContainsKey("/ImageMask") || image.Elements.GetBoolean("/ImageMask")) return;
        var filter = Single(image.Elements["/Filter"]);
        var width = image.Elements.GetInteger("/Width");
        var height = image.Elements.GetInteger("/Height");
        var bits = image.Elements.GetInteger("/BitsPerComponent");
        var space = image.Elements["/ColorSpace"] is PdfReference { Value: PdfArray } or PdfArray ? IccSpace(image.Elements["/ColorSpace"]) : image.Elements["/ColorSpace"]?.ToString() ?? "";
        if (width < 64 || height < 64) return;
        MagickImage? decoded = null;
        try
        {
            if (filter == "/DCTDecode") decoded = new MagickImage(image.Stream.Value);
            else if (filter == "/FlateDecode" && bits == 8 && space is "/DeviceRGB" or "/DeviceGray")
            {
                var raw = image.Stream.UnfilteredValue;
                var channels = space == "/DeviceRGB" ? 3 : 1;
                if (raw.Length < width * height * channels) return;
                decoded = new MagickImage(raw, new MagickReadSettings { Width = (uint)width, Height = (uint)height, Format = channels == 3 ? MagickFormat.Rgb : MagickFormat.Gray, Depth = 8 });
            }
            if (decoded == null) return;
            if (decoded.ColorSpace == ColorSpace.CMYK) return;
            if (Math.Max(decoded.Width, decoded.Height) > maxPixels) decoded.Resize(new MagickGeometry((uint)maxPixels, (uint)maxPixels));
            decoded.Quality = (uint)quality;
            // Same pixels, smaller file: optimized Huffman tables, written progressively.
            decoded.Settings.Interlace = Interlace.Jpeg;
            decoded.Settings.SetDefine(MagickFormat.Jpeg, "optimize-coding", "true");
            decoded.Strip();
            var jpeg = decoded.ToByteArray(MagickFormat.Jpeg);
            if (jpeg.Length >= image.Stream.Length * 0.9) return;
            image.Stream.Value = jpeg;
            image.Elements.SetName("/Filter", "/DCTDecode");
            image.Elements.Remove("/DecodeParms");
            image.Elements.SetInteger("/Width", (int)decoded.Width);
            image.Elements.SetInteger("/Height", (int)decoded.Height);
            image.Elements.SetInteger("/BitsPerComponent", 8);
            image.Elements.SetName("/ColorSpace", decoded.ChannelCount >= 3 ? "/DeviceRGB" : "/DeviceGray");
        }
        catch (MagickException) { }
        finally { decoded?.Dispose(); }
    }

    /// <summary>An ICC colour space (what most office apps write) read as the plain RGB or grey it holds.</summary>
    private static string IccSpace(PdfItem? item)
    {
        var array = (item as PdfReference)?.Value as PdfArray ?? item as PdfArray;
        if (array is not { Elements.Count: 2 } || array.Elements[0].ToString() != "/ICCBased") return "";
        var profile = (array.Elements[1] as PdfReference)?.Value as PdfDictionary;
        return profile?.Elements.GetInteger("/N") switch { 3 => "/DeviceRGB", 1 => "/DeviceGray", _ => "" };
    }

    /// <summary>Writes the pages in <paramref name="slots"/> order, each turned by its extra rotation. With <paramref name="equalWidths"/>,
    /// wider pages are scaled down (vectors intact) to the narrowest page's width.</summary>
    public static async Task<string> Organize(string file, IReadOnlyList<PageSlot> slots, bool equalWidths, OperationContext context)
    {
        if (slots.Count == 0) throw new AdawatException("Keep at least one page.");
        var output = Output.PathFor(file, "pdf", "organized");
        await Task.Run(() =>
        {
            using var source = Open(file, PdfDocumentOpenMode.Import);
            using var result = new PdfDocument();
            result.Info.Creator = "Adawat";
            double Upright(PdfPage page, int extra) => ((page.Rotate + extra) / 90 % 2 != 0) ? page.Height.Point : page.Width.Point;
            var narrowest = slots.Min(slot => Upright(source.Pages[slot.Source], slot.Rotation));
            using var form = equalWidths ? PdfSharp.Drawing.XPdfForm.FromFile(file) : null;
            for (var index = 0; index < slots.Count; index++)
            {
                context.Progress((double)index / slots.Count);
                var slot = slots[index];
                var page = source.Pages[slot.Source];
                var width = Upright(page, slot.Rotation);
                if (!equalWidths || width <= narrowest + 0.5)
                {
                    var added = result.AddPage(page);
                    added.Rotate = (page.Rotate + slot.Rotation) % 360;
                    continue;
                }
                // Draw the page as a form, scaled, so text and vectors stay sharp.
                var turns = (page.Rotate + slot.Rotation) / 90 % 4;
                var w = turns % 2 == 0 ? page.Width.Point : page.Height.Point;
                var h = turns % 2 == 0 ? page.Height.Point : page.Width.Point;
                var scale = narrowest / w;
                var target = result.AddPage();
                target.Width = PdfSharp.Drawing.XUnit.FromPoint(narrowest);
                target.Height = PdfSharp.Drawing.XUnit.FromPoint(h * scale);
                form!.PageIndex = slot.Source;
                using var graphics = PdfSharp.Drawing.XGraphics.FromPdfPage(target);
                graphics.ScaleTransform(scale);
                graphics.TranslateTransform(w / 2, h / 2);
                graphics.RotateTransform(turns * 90);
                graphics.TranslateTransform(-page.Width.Point / 2, -page.Height.Point / 2);
                graphics.DrawImage(form, 0, 0, page.Width.Point, page.Height.Point);
            }
            result.Save(output);
        });
        return output;
    }
}
