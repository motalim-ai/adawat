using ImageMagick;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace Adawat.Core.Images;

/// <summary>Every photo conversion and one-step photo tool.</summary>
public static class ImageOps
{
    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, ImageFormat format, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.Report($"Converting {index + 1} of {files.Count}");
            context.Progress((double)index / files.Count);
            var file = files[index];
            var output = Output.PathFor(file, format.Ext);
            await Task.Run(() =>
            {
                using var image = ImageEngine.Load(file);
                ImageEngine.Save(image, format, output, 0.9);
            });
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>Lossy formats stay as they are; lossless ones become JPEG, or WebP when they carry transparency.</summary>
    public static ImageFormat CompressedFormat(string path, MagickImage image)
    {
        if (ImageFormat.Of(path) is { Lossy: true } format && format.CanWrite) return format;
        return image.HasAlpha ? ImageFormat.WebP : ImageFormat.Jpeg;
    }

    /// <summary>The format edited copies are saved in: the original's, unless it cannot be written well.</summary>
    public static ImageFormat EditedFormat(string path)
    {
        var format = ImageFormat.Of(path) ?? ImageFormat.Png;
        return format == ImageFormat.Gif || format == ImageFormat.Ico || !format.CanWrite ? ImageFormat.Png : format;
    }

    public static async Task<IReadOnlyList<string>> Resize(IReadOnlyList<string> files, int maxPixels, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.ThrowIfCancelled();
            context.Report($"Resizing {index + 1} of {files.Count}");
            var file = files[index];
            var output = await Task.Run(() =>
            {
                using var image = ImageEngine.Load(file, maxPixels);
                var path = Output.PathFor(file, EditedFormat(file).Ext, $"{image.Width}x{image.Height}");
                ImageEngine.Save(image, EditedFormat(file), path, 0.9);
                return path;
            });
            outputs.Add(output);
        }
        return outputs;
    }

    public static async Task<IReadOnlyList<string>> RemoveMetadata(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            context.ThrowIfCancelled();
            var output = Output.PathFor(file, Path.GetExtension(file).TrimStart('.'), "clean");
            await Task.Run(() =>
            {
                using var image = new MagickImage(file);
                var format = ImageFormat.Of(file) ?? ImageFormat.Png;
                // Re-encoding at the highest quality keeps the picture while dropping every tag but the color profile.
                image.AutoOrient();
                var icc = image.GetColorProfile();
                image.Strip();
                if (icc != null) image.SetProfile(icc);
                image.Quality = 95;
                image.Write(output, format.Magick);
            });
            outputs.Add(output);
        }
        context.Finish(files.Count == 1 ? "Metadata removed from 1 image" : $"Metadata removed from {files.Count} images");
        return outputs;
    }

    /// <summary>Crops every image to the same rectangle, given as shares (0…1) of width and height from the top left.</summary>
    public static async Task<IReadOnlyList<string>> Crop(IReadOnlyList<string> files, (double X, double Y, double W, double H) rect,
                                                       OperationContext context, (int Width, int Height)? exactSize = null)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.ThrowIfCancelled();
            context.Report($"Cropping {index + 1} of {files.Count}");
            var file = files[index];
            var output = Output.PathFor(file, EditedFormat(file).Ext, "cropped");
            await Task.Run(() =>
            {
                using var image = ImageEngine.Load(file);
                var geometry = new MagickGeometry((int)Math.Round(rect.X * image.Width), (int)Math.Round(rect.Y * image.Height),
                                                  (uint)Math.Max(1, Math.Round(rect.W * image.Width)), (uint)Math.Max(1, Math.Round(rect.H * image.Height)));
                image.Crop(geometry);
                image.ResetPage();
                if (exactSize is { } size) image.Resize(new MagickGeometry((uint)size.Width, (uint)size.Height) { IgnoreAspectRatio = true });
                ImageEngine.Save(image, EditedFormat(file), output, 0.92);
            });
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>The largest centred square, for one-step runs without the crop window.</summary>
    public static async Task<IReadOnlyList<string>> SquareCrop(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            context.ThrowIfCancelled();
            double w, h;
            using (var upright = await ImageEngine.LoadAsync(file)) (w, h) = (upright.Width, upright.Height);
            var side = Math.Min(w, h);
            outputs.AddRange(await Crop([file], ((w - side) / 2 / w, (h - side) / 2 / h, side / w, side / h), context));
        }
        return outputs;
    }

    /// <summary>A quarter turn clockwise. JPEGs only change their orientation tag, so no quality is lost.</summary>
    public static async Task<IReadOnlyList<string>> Rotate(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            context.ThrowIfCancelled();
            var output = Output.PathFor(file, Path.GetExtension(file).TrimStart('.'), "rotated");
            await Task.Run(() =>
            {
                if (ImageFormat.Of(file) == ImageFormat.Jpeg && ExifOrientation.TryRotate(File.ReadAllBytes(file)) is { } rotated)
                {
                    File.WriteAllBytes(output, rotated);
                    return;
                }
                using var image = ImageEngine.Load(file);
                image.Rotate(90);
                ImageEngine.Save(image, ImageFormat.Of(file) ?? ImageFormat.Png, output, 0.95);
            });
            outputs.Add(output);
        }
        return outputs;
    }

    public static async Task<IReadOnlyList<string>> MakePdf(IReadOnlyList<string> files, OperationContext context)
    {
        context.Report(files.Count == 1 ? "Creating PDF from 1 image" : $"Creating PDF from {files.Count} images");
        var name = files.Count == 1 ? Path.GetFileNameWithoutExtension(files[0]) : "Images";
        var output = Output.Named($"{name}.pdf", files[0]);
        await Task.Run(() =>
        {
            using var document = new PdfDocument();
            document.Info.Creator = "Adawat";
            for (var index = 0; index < files.Count; index++)
            {
                context.Progress((double)index / files.Count);
                using var image = ImageEngine.Load(files[index]);
                var lossy = !image.HasAlpha;
                var bytes = ImageEngine.Encode(image, lossy ? ImageFormat.Jpeg : ImageFormat.Png, 0.92);
                using var stream = new MemoryStream(bytes);
                using var picture = XImage.FromStream(stream);
                // Pages are sized to the picture at 72 points per inch of its own resolution, so nothing is cropped.
                var dpi = image.Density.X > 1 ? image.Density.ChangeUnits(DensityUnit.PixelsPerInch).X : 144;
                var page = document.AddPage();
                page.Width = XUnit.FromPoint(image.Width * 72 / dpi);
                page.Height = XUnit.FromPoint(image.Height * 72 / dpi);
                using var graphics = XGraphics.FromPdfPage(page);
                graphics.DrawImage(picture, 0, 0, page.Width.Point, page.Height.Point);
            }
            Pdf.PdfOps.Save(document, output);
        });
        return [output];
    }

    public static async Task<IReadOnlyList<string>> ExtractText(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        var all = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.ThrowIfCancelled();
            context.Report($"Reading text {index + 1} of {files.Count}");
            var file = files[index];
            string text;
            if (FileKinds.Of(file) == FileKind.Pdf)
            {
                text = await Pdf.PdfOps.Text(file, context);
            }
            else
            {
                using var image = await ImageEngine.LoadAsync(file);
                text = await Recognition.Text(image);
            }
            text = text.Trim();
            if (text.Length == 0) continue;
            var output = Output.PathFor(file, "txt");
            await File.WriteAllTextAsync(output, text);
            outputs.Add(output);
            all.Add(text);
        }
        if (all.Count == 0) throw new AdawatException("No text found");
        Clipboard.CopyText(string.Join(Environment.NewLine + Environment.NewLine, all));
        context.Finish("Text copied to clipboard");
        return outputs;
    }

    public static async Task<IReadOnlyList<string>> ReadQrCodes(IReadOnlyList<string> files, OperationContext context)
    {
        var payloads = new List<string>();
        foreach (var file in files)
        {
            context.ThrowIfCancelled();
            using var image = await ImageEngine.LoadAsync(file);
            payloads.AddRange(Recognition.Codes(image));
        }
        if (payloads.Count == 0) throw new AdawatException("No QR codes found");
        Clipboard.CopyText(string.Join(Environment.NewLine, payloads));
        var preview = payloads[0].Length > 60 ? payloads[0][..60] + "…" : payloads[0];
        context.Finish($"Copied: {preview}");
        return [];
    }
}

/// <summary>Turns a JPEG by rewriting the EXIF orientation tag in place, the way Photos rotates without re-encoding.</summary>
internal static class ExifOrientation
{
    // Orientation after a quarter turn clockwise, by current value (1…8).
    private static readonly ushort[] Clockwise = [0, 6, 7, 8, 5, 2, 3, 4, 1];

    public static byte[]? TryRotate(byte[] jpeg)
    {
        if (jpeg.Length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
        var position = 2;
        while (position + 4 < jpeg.Length && jpeg[position] == 0xFF)
        {
            var marker = jpeg[position + 1];
            var length = (jpeg[position + 2] << 8) | jpeg[position + 3];
            if (marker == 0xE1 && length > 8 && jpeg.AsSpan(position + 4, 6).SequenceEqual("Exif\0\0"u8))
            {
                var tiff = position + 10;
                var little = jpeg[tiff] == 'I';
                ushort U16(int at) => little ? (ushort)(jpeg[at] | jpeg[at + 1] << 8) : (ushort)(jpeg[at] << 8 | jpeg[at + 1]);
                uint U32(int at) => little ? (uint)(jpeg[at] | jpeg[at + 1] << 8 | jpeg[at + 2] << 16 | jpeg[at + 3] << 24)
                                           : (uint)(jpeg[at] << 24 | jpeg[at + 1] << 16 | jpeg[at + 2] << 8 | jpeg[at + 3]);
                var ifd = tiff + (int)U32(tiff + 4);
                var count = U16(ifd);
                for (var entry = 0; entry < count; entry++)
                {
                    var at = ifd + 2 + entry * 12;
                    if (U16(at) != 0x0112) continue;
                    var current = U16(at + 8);
                    if (current is < 1 or > 8) return null;
                    var copy = (byte[])jpeg.Clone();
                    var next = Clockwise[current];
                    if (little) { copy[at + 8] = (byte)next; copy[at + 9] = 0; } else { copy[at + 8] = 0; copy[at + 9] = (byte)next; }
                    return copy;
                }
                return null;
            }
            if (marker == 0xDA) break;
            position += 2 + length;
        }
        return null;
    }
}
