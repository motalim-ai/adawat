import AppKit
import PDFKit

/// Presentations: PowerPoint and Keynote through Keynote, and PDFs turned into PowerPoint decks directly.
@MainActor
enum SlideOps {
    enum Target: String {
        case pdf, pptx, key, png, jpg
        var title: String { rawValue.uppercased() }
    }

    static func convert(_ files: [URL], to target: Target, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try await context.checkpoint()
            context.report("Converting \(index + 1) of \(files.count) with Keynote")
            let base = file.deletingPathExtension().lastPathComponent
            switch target {
            case .pdf:
                let out = Output.url(for: file, extension: "pdf")
                try await IWorkBridge.export(file, with: .keynote, as: .pdf, to: out)
                outputs.append(out)
            case .pptx:
                let out = Output.url(for: file, extension: "pptx")
                try await IWorkBridge.export(file, with: .keynote, as: .powerpoint, to: out)
                outputs.append(out)
            case .key:
                let out = Output.url(for: file, extension: "key")
                try await IWorkBridge.export(file, with: .keynote, as: .native, to: out)
                outputs.append(out)
            case .png, .jpg:
                // Keynote writes one image per slide into the folder it is given.
                let folder = Output.url(named: "\(base) slides", near: file)
                try await IWorkBridge.export(file, with: .keynote, as: .images(png: target == .png), to: folder)
                outputs.append(folder)
            }
        }
        return outputs
    }

    // MARK: PDF to PowerPoint

    /// One slide per page, each page rendered at 2× as a full-bleed picture, on slides shaped like the first page.
    static func pdfToPPTX(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            try await context.checkpoint()
            let document = try PDFOps.open(file)
            let out = Output.url(for: file, extension: "pptx")
            try await writeDeck(document, to: out, context: context)
            outputs.append(out)
        }
        return outputs
    }

    private static let emuPerPoint = 12700

    private static func writeDeck(_ document: PDFDocument, to out: URL, context: OperationContext) async throws {
        let fm = FileManager.default
        let root = Output.temporaryURL(extension: "").deletingPathExtension()
        defer { try? fm.removeItem(at: root) }
        for dir in ["_rels", "ppt/_rels", "ppt/slides/_rels", "ppt/slideLayouts/_rels", "ppt/slideMasters/_rels", "ppt/theme", "ppt/media"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        guard let first = document.page(at: 0) else { throw AdawatError.message("This PDF has no pages.") }
        let firstBox = first.bounds(for: .mediaBox)
        let turned = (first.rotation / 90) % 2 != 0
        let slideWidth = Int((turned ? firstBox.height : firstBox.width) * CGFloat(emuPerPoint))
        let slideHeight = Int((turned ? firstBox.width : firstBox.height) * CGFloat(emuPerPoint))

        var slideIDs = "", presentationRels = "", contentSlides = ""
        for index in 0..<document.pageCount {
            try await context.checkpoint()
            context.report("Building slide \(index + 1) of \(document.pageCount)")
            context.progress(Double(index) / Double(document.pageCount))
            guard let page = document.page(at: index), let image = PDFOps.render(page, dpi: 144) else { continue }
            let n = index + 1
            try ImageEngine.write(image, as: .png, to: root.appendingPathComponent("ppt/media/image\(n).png"), quality: 1, metadata: [:])
            // Fit the page inside the slide, centered, keeping its shape.
            let scale = min(Double(slideWidth) / Double(image.width), Double(slideHeight) / Double(image.height))
            let cx = Int(Double(image.width) * scale), cy = Int(Double(image.height) * scale)
            let x = (slideWidth - cx) / 2, y = (slideHeight - cy) / 2
            let slide = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            let slideRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(n).png"/></Relationships>
            """
            try slide.write(to: root.appendingPathComponent("ppt/slides/slide\(n).xml"), atomically: true, encoding: .utf8)
            try slideRels.write(to: root.appendingPathComponent("ppt/slides/_rels/slide\(n).xml.rels"), atomically: true, encoding: .utf8)
            slideIDs += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 1)\"/>"
            presentationRels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
            contentSlides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        let themeID = document.pageCount + 2
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(contentSlides)</Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
            """,
            "ppt/presentation.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
            """,
            "ppt/_rels/presentation.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(presentationRels)<Relationship Id="rId\(themeID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/></Relationships>
            """,
            "ppt/slideMasters/slideMaster1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
            """,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
            """,
            "ppt/slideLayouts/slideLayout1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
            """,
            "ppt/theme/theme1.xml": theme,
        ]
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try await ZipPackage.zip(root, to: out)
    }

    /// The smallest complete Office theme: colors, fonts and the three required style lists.
    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Adawat"><a:themeElements><a:clrScheme name="Adawat"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="EEEEEE"/></a:lt2><a:accent1><a:srgbClr val="5B47E6"/></a:accent1><a:accent2><a:srgbClr val="2F7DF6"/></a:accent2><a:accent3><a:srgbClr val="33B85A"/></a:accent3><a:accent4><a:srgbClr val="FFCC1A"/></a:accent4><a:accent5><a:srgbClr val="8E5CD9"/></a:accent5><a:accent6><a:srgbClr val="E8433A"/></a:accent6><a:hlink><a:srgbClr val="2F7DF6"/></a:hlink><a:folHlink><a:srgbClr val="8E5CD9"/></a:folHlink></a:clrScheme><a:fontScheme name="Adawat"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface="Geeza Pro"/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface="Geeza Pro"/></a:minorFont></a:fontScheme><a:fmtScheme name="Adawat"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
}
