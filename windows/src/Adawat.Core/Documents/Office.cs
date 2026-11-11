using System.Runtime.InteropServices;
using DocumentFormat.OpenXml.Packaging;

namespace Adawat.Core.Documents;

/// <summary>Formats only Microsoft Office or LibreOffice can render (old .doc, PowerPoint slides), used when one of them is
/// installed: Office through its automation interface, LibreOffice through its command line.</summary>
public static class Office
{
    public static bool HasWord => OperatingSystem.IsWindows() && Type.GetTypeFromProgID("Word.Application") != null;
    public static bool HasPowerPoint => OperatingSystem.IsWindows() && Type.GetTypeFromProgID("PowerPoint.Application") != null;

    public static string? LibreOffice
    {
        get
        {
            foreach (var root in OperatingSystem.IsWindows() ? new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) } : [])
            {
                var path = Path.Combine(root, "LibreOffice", "program", "soffice.exe");
                if (File.Exists(path)) return path;
            }
            return ProcessRunner.Find("soffice");
        }
    }

    public static bool CanRenderSlides => HasPowerPoint || LibreOffice != null;

    /// <summary>An old Word file as a document, through Word or LibreOffice.</summary>
    public static async Task<Doc> WordToDoc(string path)
    {
        using var temp = Output.Temp();
        var docx = temp.File("document.docx");
        if (HasWord)
        {
            await Sta(() =>
            {
                dynamic word = Activator.CreateInstance(Type.GetTypeFromProgID("Word.Application")!)!;
                try
                {
                    word.Visible = false;
                    word.DisplayAlerts = 0;
                    dynamic document = word.Documents.Open(path, false, true);
                    document.SaveAs2(docx, 16);
                    document.Close(false);
                }
                finally { word.Quit(); Marshal.FinalReleaseComObject(word); }
            });
        }
        else if (LibreOffice is { } soffice)
        {
            await Convert(soffice, path, "docx", temp.Path);
            docx = Path.Combine(temp.Path, Path.GetFileNameWithoutExtension(path) + ".docx");
        }
        else throw new AdawatException(OperatingSystem.IsWindows() ? "Microsoft Word is needed for this file." : Missing);
        var doc = Docx.Read(docx);
        doc.Title = Path.GetFileNameWithoutExtension(path);
        return doc;
    }

    /// <summary>A presentation exported as PDF, through PowerPoint or LibreOffice.</summary>
    public static async Task SlidesToPdf(string path, string output)
    {
        if (HasPowerPoint)
        {
            await Sta(() =>
            {
                dynamic app = Activator.CreateInstance(Type.GetTypeFromProgID("PowerPoint.Application")!)!;
                try
                {
                    dynamic deck = app.Presentations.Open(path, -1, 0, 0);
                    deck.SaveAs(output, 32);
                    deck.Close();
                }
                finally { app.Quit(); Marshal.FinalReleaseComObject(app); }
            });
            return;
        }
        if (LibreOffice is { } soffice)
        {
            using var temp = Output.Temp();
            await Convert(soffice, path, "pdf", temp.Path);
            File.Move(Path.Combine(temp.Path, Path.GetFileNameWithoutExtension(path) + ".pdf"), output, true);
            return;
        }
        throw new AdawatException(OperatingSystem.IsWindows() ? "Microsoft PowerPoint is needed for this file." : Missing);
    }

    /// <summary>A presentation saved as PowerPoint (.pptx), from .ppt or .odp.</summary>
    public static async Task SlidesToPptx(string path, string output)
    {
        if (HasPowerPoint)
        {
            await Sta(() =>
            {
                dynamic app = Activator.CreateInstance(Type.GetTypeFromProgID("PowerPoint.Application")!)!;
                try
                {
                    dynamic deck = app.Presentations.Open(path, -1, 0, 0);
                    deck.SaveAs(output, 24);
                    deck.Close();
                }
                finally { app.Quit(); Marshal.FinalReleaseComObject(app); }
            });
            return;
        }
        if (LibreOffice is { } soffice)
        {
            using var temp = Output.Temp();
            await Convert(soffice, path, "pptx", temp.Path);
            File.Move(Path.Combine(temp.Path, Path.GetFileNameWithoutExtension(path) + ".pptx"), output, true);
            return;
        }
        throw new AdawatException(OperatingSystem.IsWindows() ? "Microsoft PowerPoint is needed for this file." : Missing);
    }

#if WINDOWS
    private const string Missing = "LibreOffice is needed for this file.";
#else
    private static string Missing => $"LibreOffice is needed for this file. Install it with: {Desktop.Install("libreoffice", pacman: "libreoffice-fresh")}";
#endif

    private static async Task Convert(string soffice, string path, string format, string folder)
    {
        var result = await ProcessRunner.Run(soffice, ["--headless", "--norestore", "--convert-to", format, "--outdir", folder, path]);
        if (result.ExitCode != 0) throw new AdawatException($"LibreOffice could not convert {Path.GetFileName(path)}.");
    }

    private static Task Sta(Action action) => Task.Run(() => Documents.Sta.Run(action));
}

/// <summary>Presentations: to PDF and pictures (through PowerPoint or LibreOffice), and PDF to PowerPoint, one slide per page.</summary>
public static class SlideOps
{
    public static IReadOnlyList<string> Targets => ["pdf", "pptx", "png", "jpg"];

    public static string Title(string target) => target switch { "jpg" => "JPEG", _ => target.ToUpperInvariant() };

    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, string target, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.ThrowIfCancelled();
            context.Report($"Converting {index + 1} of {files.Count}");
            var file = files[index];
            switch (target)
            {
                case "pdf":
                {
                    var output = Output.PathFor(file, "pdf");
                    await Office.SlidesToPdf(file, output);
                    outputs.Add(output);
                    break;
                }
                case "pptx":
                {
                    var output = Output.PathFor(file, "pptx");
                    await Office.SlidesToPptx(file, output);
                    outputs.Add(output);
                    break;
                }
                default:
                {
                    using var temp = Output.Temp();
                    var pdf = temp.File("slides.pdf");
                    await Office.SlidesToPdf(file, pdf);
                    var format = target == "png" ? Images.ImageFormat.Png : Images.ImageFormat.Jpeg;
                    var folder = Output.Named($"{Path.GetFileNameWithoutExtension(file)} slides", file);
                    Directory.CreateDirectory(folder);
                    var count = Pdf.PdfOps.PageCount(pdf);
                    for (var page = 0; page < count; page++)
                    {
                        context.Report($"Rendering page {page + 1} of {count}");
                        await Task.Run(() =>
                        {
                            using var image = Pdf.PdfOps.RenderPage(pdf, page, 200);
                            Images.ImageEngine.Save(image, format, Path.Combine(folder, $"Slide {page + 1}.{format.Ext}"), 0.9);
                        });
                    }
                    outputs.Add(folder);
                    break;
                }
            }
        }
        return outputs;
    }

    /// <summary>Each PDF page becomes a full-bleed slide sized like the page, so nothing shifts.</summary>
    public static async Task<IReadOnlyList<string>> PdfToPptx(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            context.ThrowIfCancelled();
            var output = Output.PathFor(file, "pptx");
            await Task.Run(() =>
            {
                var count = Pdf.PdfOps.PageCount(file);
                var slides = new List<(byte[] Png, long Cx, long Cy)>();
                for (var page = 0; page < count; page++)
                {
                    context.Report($"Building slide {page + 1} of {count}");
                    context.Progress((double)page / count);
                    using var image = Pdf.PdfOps.RenderPage(file, page, 200);
                    const long emuPerInch = 914400;
                    slides.Add((image.ToByteArray(ImageMagick.MagickFormat.Png), image.Width * emuPerInch / 200, image.Height * emuPerInch / 200));
                }
                Pptx.Write(slides, output);
            });
            outputs.Add(output);
        }
        return outputs;
    }
}

/// <summary>A minimal PowerPoint file: one picture per slide.</summary>
internal static class Pptx
{
    public static void Write(List<(byte[] Png, long Cx, long Cy)> slides, string path)
    {
        using var deck = DocumentFormat.OpenXml.Packaging.PresentationDocument.Create(path, DocumentFormat.OpenXml.PresentationDocumentType.Presentation);
        var presentationPart = deck.AddPresentationPart();
        var (cx, cy) = slides.Count > 0 ? (slides[0].Cx, slides[0].Cy) : (12192000L, 6858000L);
        var master = presentationPart.AddNewPart<DocumentFormat.OpenXml.Packaging.SlideMasterPart>("rId1");
        var layout = master.AddNewPart<DocumentFormat.OpenXml.Packaging.SlideLayoutPart>("rId1");
        layout.SlideLayout = new DocumentFormat.OpenXml.Presentation.SlideLayout(
            new DocumentFormat.OpenXml.Presentation.CommonSlideData(EmptyTree()), new DocumentFormat.OpenXml.Presentation.ColorMapOverride(new DocumentFormat.OpenXml.Drawing.MasterColorMapping()))
        { Type = DocumentFormat.OpenXml.Presentation.SlideLayoutValues.Blank };
        var theme = master.AddNewPart<DocumentFormat.OpenXml.Packaging.ThemePart>("rId2");
        theme.Theme = Theme();
        master.SlideMaster = new DocumentFormat.OpenXml.Presentation.SlideMaster(
            new DocumentFormat.OpenXml.Presentation.CommonSlideData(EmptyTree()),
            new DocumentFormat.OpenXml.Presentation.ColorMap
            {
                Background1 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Light1, Text1 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Dark1,
                Background2 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Light2, Text2 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Dark2,
                Accent1 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent1, Accent2 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent2,
                Accent3 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent3, Accent4 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent4,
                Accent5 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent5, Accent6 = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Accent6,
                Hyperlink = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.Hyperlink, FollowedHyperlink = DocumentFormat.OpenXml.Drawing.ColorSchemeIndexValues.FollowedHyperlink,
            },
            new DocumentFormat.OpenXml.Presentation.SlideLayoutIdList(new DocumentFormat.OpenXml.Presentation.SlideLayoutId { Id = 2147483649U, RelationshipId = "rId1" }));
        var slideIds = new DocumentFormat.OpenXml.Presentation.SlideIdList();
        uint id = 256;
        foreach (var (png, w, h) in slides)
        {
            var slidePart = presentationPart.AddNewPart<DocumentFormat.OpenXml.Packaging.SlidePart>();
            slidePart.AddPart(layout);
            var imagePart = slidePart.AddImagePart(DocumentFormat.OpenXml.Packaging.ImagePartType.Png);
            using (var stream = new MemoryStream(png)) imagePart.FeedData(stream);
            var relation = slidePart.GetIdOfPart(imagePart);
            var tree = EmptyTree();
            tree.Append(new DocumentFormat.OpenXml.Presentation.Picture(
                new DocumentFormat.OpenXml.Presentation.NonVisualPictureProperties(
                    new DocumentFormat.OpenXml.Presentation.NonVisualDrawingProperties { Id = 2, Name = "Page" },
                    new DocumentFormat.OpenXml.Presentation.NonVisualPictureDrawingProperties(new DocumentFormat.OpenXml.Drawing.PictureLocks { NoChangeAspect = true }),
                    new DocumentFormat.OpenXml.Presentation.ApplicationNonVisualDrawingProperties()),
                new DocumentFormat.OpenXml.Presentation.BlipFill(new DocumentFormat.OpenXml.Drawing.Blip { Embed = relation },
                                                                 new DocumentFormat.OpenXml.Drawing.Stretch(new DocumentFormat.OpenXml.Drawing.FillRectangle())),
                new DocumentFormat.OpenXml.Presentation.ShapeProperties(
                    new DocumentFormat.OpenXml.Drawing.Transform2D(new DocumentFormat.OpenXml.Drawing.Offset { X = 0, Y = 0 }, new DocumentFormat.OpenXml.Drawing.Extents { Cx = cx, Cy = cx * h / Math.Max(1, w) }),
                    new DocumentFormat.OpenXml.Drawing.PresetGeometry(new DocumentFormat.OpenXml.Drawing.AdjustValueList()) { Preset = DocumentFormat.OpenXml.Drawing.ShapeTypeValues.Rectangle })));
            slidePart.Slide = new DocumentFormat.OpenXml.Presentation.Slide(new DocumentFormat.OpenXml.Presentation.CommonSlideData(tree));
            slideIds.Append(new DocumentFormat.OpenXml.Presentation.SlideId { Id = id++, RelationshipId = presentationPart.GetIdOfPart(slidePart) });
        }
        presentationPart.Presentation = new DocumentFormat.OpenXml.Presentation.Presentation(
            new DocumentFormat.OpenXml.Presentation.SlideMasterIdList(new DocumentFormat.OpenXml.Presentation.SlideMasterId { Id = 2147483648U, RelationshipId = "rId1" }),
            slideIds,
            new DocumentFormat.OpenXml.Presentation.SlideSize { Cx = (int)cx, Cy = (int)cy },
            new DocumentFormat.OpenXml.Presentation.NotesSize { Cx = 6858000, Cy = 9144000 });
    }

    private static DocumentFormat.OpenXml.Presentation.ShapeTree EmptyTree() => new(
        new DocumentFormat.OpenXml.Presentation.NonVisualGroupShapeProperties(
            new DocumentFormat.OpenXml.Presentation.NonVisualDrawingProperties { Id = 1, Name = "" },
            new DocumentFormat.OpenXml.Presentation.NonVisualGroupShapeDrawingProperties(),
            new DocumentFormat.OpenXml.Presentation.ApplicationNonVisualDrawingProperties()),
        new DocumentFormat.OpenXml.Presentation.GroupShapeProperties(new DocumentFormat.OpenXml.Drawing.TransformGroup()));

    private static DocumentFormat.OpenXml.Drawing.Theme Theme()
    {
        DocumentFormat.OpenXml.Drawing.SolidFill Fill(string hex) => new(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = hex });
        var scheme = new DocumentFormat.OpenXml.Drawing.ColorScheme(
            new DocumentFormat.OpenXml.Drawing.Dark1Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "000000" }),
            new DocumentFormat.OpenXml.Drawing.Light1Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "FFFFFF" }),
            new DocumentFormat.OpenXml.Drawing.Dark2Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "1F1F1F" }),
            new DocumentFormat.OpenXml.Drawing.Light2Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "EEEEEE" }),
            new DocumentFormat.OpenXml.Drawing.Accent1Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "5B47E6" }),
            new DocumentFormat.OpenXml.Drawing.Accent2Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "2F7DF6" }),
            new DocumentFormat.OpenXml.Drawing.Accent3Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "33B85A" }),
            new DocumentFormat.OpenXml.Drawing.Accent4Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "FFCC1A" }),
            new DocumentFormat.OpenXml.Drawing.Accent5Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "8E5CD9" }),
            new DocumentFormat.OpenXml.Drawing.Accent6Color(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "E8433A" }),
            new DocumentFormat.OpenXml.Drawing.Hyperlink(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "2F7DF6" }),
            new DocumentFormat.OpenXml.Drawing.FollowedHyperlinkColor(new DocumentFormat.OpenXml.Drawing.RgbColorModelHex { Val = "8E5CD9" })) { Name = "Adawat" };
        var fonts = new DocumentFormat.OpenXml.Drawing.FontScheme(
            new DocumentFormat.OpenXml.Drawing.MajorFont(new DocumentFormat.OpenXml.Drawing.LatinFont { Typeface = "Segoe UI" }, new DocumentFormat.OpenXml.Drawing.EastAsianFont { Typeface = "" }, new DocumentFormat.OpenXml.Drawing.ComplexScriptFont { Typeface = "Arial" }),
            new DocumentFormat.OpenXml.Drawing.MinorFont(new DocumentFormat.OpenXml.Drawing.LatinFont { Typeface = "Segoe UI" }, new DocumentFormat.OpenXml.Drawing.EastAsianFont { Typeface = "" }, new DocumentFormat.OpenXml.Drawing.ComplexScriptFont { Typeface = "Arial" })) { Name = "Adawat" };
        var formats = new DocumentFormat.OpenXml.Drawing.FormatScheme(
            new DocumentFormat.OpenXml.Drawing.FillStyleList(Fill("FFFFFF"), Fill("FFFFFF"), Fill("FFFFFF")),
            new DocumentFormat.OpenXml.Drawing.LineStyleList(new DocumentFormat.OpenXml.Drawing.Outline(Fill("000000")) { Width = 9525 }, new DocumentFormat.OpenXml.Drawing.Outline(Fill("000000")) { Width = 25400 }, new DocumentFormat.OpenXml.Drawing.Outline(Fill("000000")) { Width = 38100 }),
            new DocumentFormat.OpenXml.Drawing.EffectStyleList(new DocumentFormat.OpenXml.Drawing.EffectStyle(new DocumentFormat.OpenXml.Drawing.EffectList()), new DocumentFormat.OpenXml.Drawing.EffectStyle(new DocumentFormat.OpenXml.Drawing.EffectList()), new DocumentFormat.OpenXml.Drawing.EffectStyle(new DocumentFormat.OpenXml.Drawing.EffectList())),
            new DocumentFormat.OpenXml.Drawing.BackgroundFillStyleList(Fill("FFFFFF"), Fill("FFFFFF"), Fill("FFFFFF"))) { Name = "Adawat" };
        return new DocumentFormat.OpenXml.Drawing.Theme(new DocumentFormat.OpenXml.Drawing.ThemeElements(scheme, fonts, formats)) { Name = "Adawat" };
    }
}
