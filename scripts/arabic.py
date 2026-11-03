#!/usr/bin/env python3
"""Arabic translations for Adawat. Writes Resources/ar.lproj/Localizable.strings (exact text) and
Patterns.strings (text with values: {1}, {2}… in both languages mark the values).

usage: arabic.py
"""
import pathlib
import re

STATIC = {
    # Wheel modes and general
    "Convert": "تحويل", "Tools": "أدوات", "Actions": "إجراءات", "Convert wheel": "عجلة التحويل",
    "Tools wheel": "عجلة الأدوات", "Actions wheel": "عجلة الإجراءات", "NO OPTIONS": "لا خيارات",
    "Apply": "تطبيق", "Back": "رجوع", "Continue": "متابعة", "Close": "إغلاق", "Reset": "إعادة ضبط",
    "Save": "حفظ", "Set": "تعيين", "Stop": "إيقاف", "Play": "تشغيل", "Open": "فتح", "Preview": "معاينة",
    "Original": "الأصل", "Edited": "معدّل", "Restore Defaults": "استعادة الافتراضي", "Get Started": "ابدأ",
    "Untitled": "بدون عنوان", "Adawat": "أدوات",
    # Menu bar and settings
    "New Float": "Float جديد", "Close All Floats": "إغلاق كل الـ Floats", "Welcome Guide…": "دليل البداية…",
    "Settings…": "الإعدادات…", "Quit Adawat": "إنهاء أدوات", "Adawat Settings": "إعدادات تطبيق أدوات",
    "Adawat — drag files, then press a modifier key": "أدوات — اسحب الملفات ثم اضغط مفتاحًا",
    "Shortcuts while dragging": "الاختصارات أثناء السحب",
    "Drag files anywhere, then press the key to open its wheel right away.": "اسحب الملفات من أي مكان، ثم اضغط المفتاح لتظهر عجلته فورًا.",
    "Results": "النتائج", "Save results": "حفظ النتائج", "Next to the original": "بجانب الملف الأصلي",
    "Downloads folder": "مجلد التنزيلات", "Desktop": "سطح المكتب", "Show results in a Float": "عرض النتائج في Float",
    "Sound and haptic feedback": "الصوت والاهتزاز", "Compression": "الضغط", "Default preset": "الإعداد الافتراضي",
    "Resize longest edge": "أطول ضلع عند التصغير", "Video": "الفيديو", "Quality": "الجودة", "High quality": "جودة عالية",
    "Smallest file": "أصغر حجم", "General": "عام", "Launch Adawat at login": "تشغيل أدوات عند تسجيل الدخول",
    "Not found — brew install ffmpeg": "غير موجود — brew install ffmpeg", "Language": "اللغة",
    "Option": "Option", "Control": "Control", "Shift": "Shift", "Command": "Command", "Fn": "Fn",
    # Welcome
    "Welcome to Adawat": "أهلًا بك في أدوات",
    "Convert, compress and edit any file while you drag it. Everything stays on your Mac.": "حوّل واضغط وعدّل أي ملف وأنت تسحبه. كل شيء يتم على جهازك.",
    "Try it now": "جرّبها الآن", "Step 1. Drag the photo.": "الخطوة 1: اسحب الصورة.",
    "Step 2. While dragging, press a key.": "الخطوة 2: أثناء السحب، اضغط مفتاحًا.", "Drag this file": "اسحب هذا الملف",
    "That's it. Drop the photo on a format to convert it.": "هذا كل شيء. أفلت الصورة على صيغة لتحويلها.",
    "The wheel stays open until you drop.": "تبقى العجلة مفتوحة حتى تُفلت الملف.", "Make it yours": "خصّصه لك",
    "Adawat restarts to change the language.": "يُعاد تشغيل التطبيق لتغيير اللغة.", "Restart Now": "أعد التشغيل الآن",
    "Open Adawat when you log in": "افتح أدوات عند تسجيل الدخول",
    "Adawat lives in your menu bar, so it is ready whenever you drag a file.": "تطبيق أدوات يعيش في شريط القوائم، فهو جاهز كلما سحبت ملفًا.",
    "You're all set": "كل شيء جاهز",
    "Find the Adawat icon near the clock in your menu bar for Floats, Settings and this guide.": "ستجد أيقونة أدوات بجانب الساعة في شريط القوائم، ومنها الـ Floats والإعدادات وهذا الدليل.",
    "Allow Adawat in macOS Login Items to finish setup.": "اسمح لتطبيق أدوات في عناصر الدخول بالنظام لإكمال الإعداد.",
    # Float
    "Float": "Float", "Drop files here": "أفلت الملفات هنا", "Drag to carry all files": "اسحب لنقل كل الملفات",
    "Drag to carry the selection": "اسحب لنقل المحدد", "Share with AirDrop": "مشاركة عبر AirDrop",
    "Quick Look (Space)": "نظرة سريعة (مسافة)", "Quick Look": "نظرة سريعة", "Attach to the screen edge": "ألصق بحافة الشاشة",
    "Attach to Screen Edge": "ألصق بحافة الشاشة", "Close Float without deleting files": "أغلق الـ Float دون حذف الملفات",
    "Close Float": "إغلاق الـ Float", "Open Float": "فتح الـ Float", "Show in Finder": "إظهار في Finder",
    "Copy Path": "نسخ المسار", "Remove from Float": "إزالة من الـ Float",
    "Click to open the Float. Drag away from the edge to detach. Right-click to close.": "انقر لفتح الـ Float. اسحبه بعيدًا عن الحافة لفصله. انقر بالزر الأيمن للإغلاق.",
    # Actions
    "AirDrop": "AirDrop", "Copy": "نسخ", "Move": "نقل", "Terminal": "Terminal", "Move Here": "انقل هنا",
    "Move cancelled": "أُلغي النقل", "Path copied": "نُسخ المسار", "File copied": "نُسخ الملف",
    "Sharing with AirDrop": "جارٍ المشاركة عبر AirDrop", "AirDrop isn't available right now": "AirDrop غير متاح الآن",
    "Shown in Finder": "ظهر في Finder", "Added to a new Float": "أُضيف إلى Float جديد",
    # Image tools
    "Compress": "ضغط", "Metadata": "البيانات", "Edit Metadata": "تعديل البيانات", "Remove Metadata": "حذف البيانات",
    "Edit": "تعديل", "Edit Photo": "تعديل الصورة", "Annotate": "تعليق", "Annotate Photo": "التعليق على الصورة",
    "Add BG": "خلفية", "Add Background": "إضافة خلفية", "Crop": "قص", "Crop Image": "قص الصورة", "Redact": "إخفاء",
    "Redact Photo": "إخفاء أجزاء من الصورة", "Rotate": "تدوير", "Text": "نص", "Copy Text": "نسخ النص",
    "QR Code": "رمز QR", "Read QR Code": "قراءة رمز QR", "PDF": "PDF", "Create PDF": "إنشاء PDF",
    "Collage": "مجمّعة", "Create Collage": "إنشاء صورة مجمّعة", "Resize": "تغيير الحجم", "Images": "الصور",
    "No QR codes found": "لم يُعثر على رمز QR", "No text found": "لم يُعثر على نص", "Text copied to clipboard": "نُسخ النص إلى الحافظة",
    "Metadata saved": "حُفظت البيانات",
    # Compress window
    "Compression preset": "إعداد الضغط", "Light": "خفيف", "Balanced": "متوازن", "Strong": "قوي",
    "Better visual quality with moderate file-size savings.": "جودة أفضل مع توفير معتدل في الحجم.",
    "Smaller files with less quality loss.": "ملفات أصغر مع فقد أقل في الجودة.",
    "Smaller files with more quality loss.": "ملفات أصغر مع فقد أكبر في الجودة.",
    "Image size": "حجم الصورة", "Keep original dimensions": "الإبقاء على الأبعاد الأصلية", "Maximum video height": "أقصى ارتفاع للفيديو",
    "Keep original": "الإبقاء على الأصل", "Compress to target file size": "الضغط إلى حجم محدد",
    "Compression mode": "طريقة الضغط", "Target file size": "الحجم المطلوب", "File size reduction": "نسبة التقليل",
    "Size of each file": "حجم كل ملف", "Reduce by": "قلّل بنسبة", "Expected size:": "الحجم المتوقع:",
    "Enter a target size of at least 1 KB.": "أدخل حجمًا لا يقل عن 1 كيلوبايت.",
    "Target size cannot exceed the original file size.": "لا يمكن أن يتجاوز الحجم المطلوب حجم الملف الأصلي.",
    "Already as small as this preset gets. Try Strong or a target size.": "الملف صغير بالفعل بهذا الإعداد. جرّب «قوي» أو حجمًا محددًا.",
    # Crop
    "Aspect ratio": "نسبة الأبعاد", "Free": "حر", "Crop selection. Drag to reposition.": "منطقة القص. اسحبها لتحريكها.",
    "Crop Video": "قص الفيديو", "Could not crop the image": "تعذّر قص الصورة",
    # Edit photo
    "Color": "اللون", "Detail": "التفاصيل", "Effects": "المؤثرات", "Exposure": "التعريض",
    "Brightness": "السطوع", "Contrast": "التباين", "Highlights": "الإضاءات", "Shadows": "الظلال", "Whites": "الأبيض",
    "Blacks": "الأسود", "Gamma": "جاما", "Temperature": "الحرارة", "Tint": "الصبغة", "Saturation": "التشبع",
    "Vibrance": "الحيوية", "Hue": "تدرج اللون", "Clarity": "الوضوح", "Dehaze": "إزالة الضباب", "Sharpness": "الحدة",
    "Noise Reduction": "تقليل التشويش", "Vignette": "التعتيم الطرفي", "Grain": "الحبيبات", "Fade": "البهتان",
    "Save Edited Copy": "حفظ نسخة معدّلة", "Saving edited copy": "جارٍ حفظ النسخة المعدّلة",
    "Hold to compare with the original": "اضغط مطولًا للمقارنة بالأصل", "Could not render the edited image": "تعذّر إنشاء الصورة المعدّلة",
    # Annotate
    "Arrow": "سهم", "Highlight": "تظليل", "Rectangle": "مستطيل", "Ellipse": "دائرة", "Draw": "رسم حر",
    "Numbered Callout": "رقم توضيحي", "Magnifier": "عدسة تكبير", "Image": "صورة",
    "Drag from the tail toward the arrowhead. Drag an annotation to move it.": "اسحب من ذيل السهم نحو رأسه. اسحب أي عنصر لتحريكه.",
    "Drag over the image to highlight.": "اسحب فوق الصورة للتظليل.",
    "Click to add a text box, then type below. Drag a box to move it.": "انقر لإضافة مربع نص ثم اكتب بالأسفل. اسحب المربع لتحريكه.",
    "Drag on the image to draw. Drag an annotation to move it.": "اسحب على الصورة للرسم. اسحب أي عنصر لتحريكه.",
    "Drag to draw freehand. Undo removes the last stroke.": "اسحب للرسم الحر. «تراجع» يحذف آخر خط.",
    "Click to add numbered callouts; drag to move them. Their size stays fixed.": "انقر لإضافة أرقام توضيحية واسحبها لتحريكها. حجمها ثابت.",
    "Drag out from the spot to magnify. Drag a magnifier to move it.": "اسحب من النقطة المراد تكبيرها. اسحب العدسة لتحريكها.",
    "Paste an image with ⌘V or choose one. Drag it to move.": "الصق صورة بـ ⌘V أو اخترها. اسحبها لتحريكها.",
    "Undo last annotation": "التراجع عن آخر عنصر", "Delete selected annotation": "حذف العنصر المحدد",
    "Save Annotated Copy": "حفظ نسخة بالتعليقات", "Saving annotated copy": "جارٍ حفظ النسخة",
    "Could not prepare the annotated image.": "تعذّر تجهيز الصورة.",
    # Add background
    "Background": "الخلفية", "Choose an image background": "اختر صورة خلفية", "Blurred copy of the photo": "نسخة مموّهة من الصورة",
    "Custom color": "لون مخصص", "Padding": "الهامش", "Corners": "الزوايا", "Shadow": "الظل", "Ratio": "النسبة", "Auto": "تلقائي",
    "Save with Background": "حفظ بالخلفية", "Choose a background image": "اختر صورة الخلفية", "Choose a background image.": "اختر صورة الخلفية.",
    "This frame would be too large. Use less padding or a closer output ratio.": "سيكون الإطار كبيرًا جدًا. قلّل الهامش أو اختر نسبة أقرب.",
    "Could not prepare the image background.": "تعذّر تجهيز الخلفية.", "Could not finish adding the background.": "تعذّر إكمال إضافة الخلفية.",
    # Redact
    "Style": "النمط", "Solid": "مصمت", "Blur": "تمويه", "Detect": "اكتشاف", "Faces": "الوجوه",
    "Blur softens details. Use Solid for sensitive information.": "التمويه يخفف التفاصيل فقط. استخدم «مصمت» للمعلومات الحساسة.",
    "Draw rectangles over the areas to hide. Drag a box to move it, or its corners to resize.": "ارسم مستطيلات فوق ما تريد إخفاءه. اسحب المربع لتحريكه أو زواياه لتغيير حجمه.",
    "Delete Redaction": "حذف الإخفاء", "Save Redacted Copy": "حفظ نسخة مُخفاة", "Saving redacted copy": "جارٍ حفظ النسخة المُخفاة",
    "Detecting faces…": "جارٍ اكتشاف الوجوه…", "Detecting text…": "جارٍ اكتشاف النص…", "No faces found": "لم يُعثر على وجوه",
    # Collage
    "Grid": "شبكة", "Row": "صف", "Column": "عمود", "Featured": "مميزة", "Columns": "الأعمدة", "Canvas": "اللوحة",
    "Width": "العرض", "Image fit": "ملاءمة الصور", "Fill cells (crop edges)": "ملء الخانات (قص الأطراف)",
    "Fit whole images": "إظهار الصور كاملة", "Spacing & background": "المسافات والخلفية", "Spacing": "المسافة",
    "Size": "الحجم", "Layout": "التخطيط",
    "−16 LUFS is a balanced default for spoken audio and music. The true peak limit helps prevent clipping after encoding.":
        "‎−16 LUFS قيمة متوازنة للكلام والموسيقى. وحدّ الذروة الحقيقية يساعد على منع التشوّه بعد الترميز.",
    "Image order": "ترتيب الصور", "Reset Layout": "إعادة ضبط التخطيط", "Creating collage": "جارٍ إنشاء الصورة المجمّعة",
    "Square · 1:1": "مربع · 1:1", "Portrait · 4:5": "طولي · 4:5", "Story · 9:16": "قصة · 9:16",
    "Landscape · 16:9": "عرضي · 16:9", "Classic · 4:3": "كلاسيكي · 4:3", "Portrait · 9:16": "طولي · 9:16",
    "Could not create the collage canvas.": "تعذّر إنشاء لوحة الصورة المجمّعة.", "Could not render the collage.": "تعذّر إنشاء الصورة المجمّعة.",
    # Metadata
    "Search metadata": "ابحث في البيانات", "Remove All": "حذف الكل", "No matching metadata.": "لا توجد بيانات مطابقة.",
    "For photos, Remove All also clears hidden camera and processing data. The original stays unchanged.": "في الصور، «حذف الكل» يزيل أيضًا بيانات الكاميرا والمعالجة المخفية. يبقى الأصل كما هو.",
    "Keep this field": "إبقاء هذا الحقل", "Remove this field": "حذف هذا الحقل", "File": "الملف", "Format": "الصيغة",
    "Dimensions": "الأبعاد", "File Size": "حجم الملف", "Bits Per Sample": "البتات لكل عينة", "Color Model": "نموذج الألوان",
    "Color Profile": "ملف الألوان", "Resolution": "الدقة", "Gain map present": "يحتوي خريطة HDR", "Camera": "الكاميرا",
    "Description": "الوصف", "Rights": "الحقوق", "History": "السجل", "Camera Raw": "Camera Raw",
    "This file type's metadata cannot be edited here.": "لا يمكن تعديل بيانات هذا النوع من الملفات هنا.",
    # Video and audio windows
    "Trim": "قص", "Trim Video": "قص الفيديو", "Trim Audio": "قص الصوت", "Drag the ends to trim": "اسحب الطرفين للقص",
    "Start": "البداية", "End": "النهاية", "Trim silent ends automatically": "قص السكوت من الطرفين تلقائيًا",
    "Play Selected Range": "تشغيل الجزء المحدد", "Play the selection": "تشغيل المحدد", "Previous frame": "الإطار السابق",
    "Next frame": "الإطار التالي", "Change Speed": "تغيير السرعة", "Change Video Speed": "تغيير سرعة الفيديو",
    "Speed": "السرعة", "Playback speed": "سرعة التشغيل", "Preview at this speed": "معاينة بهذه السرعة",
    "Split": "تقسيم", "Split Video": "تقسيم الفيديو", "Add Split": "إضافة نقطة تقسيم", "Equal clips": "مقاطع متساوية",
    "Join the rest into one video": "دمج الباقي في فيديو واحد", "Export separate clips": "تصدير مقاطع منفصلة",
    "Click a clip in the timeline, then press Delete to remove it. Space plays the video.": "انقر مقطعًا في الشريط ثم اضغط Delete لحذفه. المسافة تشغّل الفيديو.",
    "Press Delete to remove this clip.": "اضغط Delete لحذف هذا المقطع.", "Press Delete again to keep this clip.": "اضغط Delete مرة أخرى لإبقاء هذا المقطع.",
    "Keep at least one clip.": "أبقِ مقطعًا واحدًا على الأقل.", "Frames": "لقطات", "Save Frames": "حفظ لقطات",
    "Video Snapshots": "لقطات الفيديو", "Add Frame": "إضافة لقطة", "Save 1 Frame": "حفظ لقطة واحدة",
    "Remove selected frame": "حذف اللقطة المحددة", "Add a frame to save.": "أضف لقطة لحفظها.",
    "Redact Video": "إخفاء أجزاء من الفيديو", "Redactions": "مناطق الإخفاء", "Show for Entire Video": "إظهار طوال الفيديو",
    "Draw rectangles on the video to cover areas. Each one gets its own time range here.": "ارسم مستطيلات على الفيديو لتغطية مناطق. لكل منها مدة خاصة هنا.",
    "Draw at least one redaction.": "ارسم منطقة إخفاء واحدة على الأقل.", "Join": "دمج", "Join Videos": "دمج الفيديوهات",
    "Playback order": "ترتيب التشغيل", "Select at least two videos to join.": "اختر فيديوهين على الأقل للدمج.",
    "Every selected file must contain a video track.": "يجب أن يحتوي كل ملف على فيديو.", "Mute": "كتم الصوت",
    "Normalize": "توحيد", "Normalize Volume": "توحيد مستوى الصوت", "Normalize Audio": "توحيد الصوت",
    "Target loudness": "مستوى الصوت المطلوب", "Loudness range": "مدى الصوت", "True peak limit": "حد الذروة",
    "Measuring loudness": "جارٍ قياس مستوى الصوت", "Normalizing": "جارٍ التوحيد",
    "Visualizer": "موجة صوت", "Audio Visualizer": "فيديو بموجة الصوت", "Waveform": "موجة", "Still image": "صورة ثابتة",
    "Shape": "الشكل", "Choose Image…": "اختر صورة…", "Create Visualization": "إنشاء الفيديو",
    "Choose an image for the visualization.": "اختر صورة للفيديو.", "Channels": "القنوات", "Convert Channels": "تحويل القنوات",
    "Convert Audio Channels": "تحويل قنوات الصوت", "Output channel preview": "معاينة القنوات", "Output": "الإخراج",
    "Mono": "أحادي", "Stereo": "ستيريو", "Left volume": "صوت اليسار", "Right volume": "صوت اليمين",
    "Play Output": "تشغيل النتيجة", "Play this channel on its own": "تشغيل هذه القناة وحدها",
    "Choose Mono or Stereo for a file with an audio track.": "اختر أحادي أو ستيريو لملف فيه صوت.",
    "Bleep": "تصفير", "Bleeps": "التصفيرات", "Bleep Audio": "تصفير الصوت", "Bleep Entire Audio": "تصفير الصوت كله",
    "Add bleep at playhead": "تصفير عند المؤشر", "With Bleeps": "مع التصفير", "Save Bleeped Copy": "حفظ النسخة المُصفّرة",
    "Drag across the Bleep layer to add a section, then drag a section or either edge to adjust it. Delete removes the selected one.": "اسحب على طبقة التصفير لإضافة جزء، ثم اسحب الجزء أو طرفيه لضبطه. Delete يحذف المحدد.",
    "Add at least one bleep range.": "أضف جزء تصفير واحدًا على الأقل.", "Silence": "السكوت", "Trim Silence": "قص السكوت",
    "To Mono": "إلى أحادي", "Audio": "الصوت",
    "This file has no audio track": "لا يحتوي هذا الملف على صوت", "This file has no audio track.": "لا يحتوي هذا الملف على صوت.",
    "This file has no playable audio.": "لا يحتوي هذا الملف على صوت قابل للتشغيل.", "This file has no video track": "لا يحتوي هذا الملف على فيديو",
    # PDF
    "Merge": "دمج", "Merge PDFs": "دمج ملفات PDF", "Document order": "ترتيب المستندات", "Split Pages": "تقسيم الصفحات",
    "Organize": "ترتيب", "Organize Pages": "ترتيب الصفحات", "Organize PDF": "ترتيب صفحات PDF", "Reset Order": "إعادة الترتيب",
    "Make all pages the same width": "توحيد عرض كل الصفحات",
    "Pages are scaled proportionally to match the narrowest page; their heights may still differ. Drag pages to reorder them; right-click for more.": "تُصغَّر الصفحات بالتناسب لتطابق أضيق صفحة، وقد تختلف ارتفاعاتها. اسحب الصفحات لترتيبها، وانقر بالزر الأيمن للمزيد.",
    "Rotate Clockwise": "تدوير مع عقارب الساعة", "Rotate clockwise": "تدوير مع عقارب الساعة", "Duplicate Page": "تكرار الصفحة",
    "Delete Page": "حذف الصفحة", "Save Organized PDF": "حفظ PDF المرتب", "Keep at least one page.": "أبقِ صفحة واحدة على الأقل.",
    "Organize needs its window.": "الترتيب يحتاج نافذته.", "This tool needs its window.": "هذه الأداة تحتاج نافذتها.",
    "These PDFs are already as small as they get": "ملفات PDF هذه صغيرة بالفعل", "This PDF has no pages.": "لا يحتوي هذا الملف على صفحات.",
    "Could not create the PDF": "تعذّر إنشاء PDF", "Could not create the compressed PDF": "تعذّر إنشاء PDF المضغوط",
    "Could not create the organized PDF.": "تعذّر إنشاء PDF المرتب.", "Could not write the cleaned PDF": "تعذّر حفظ PDF",
    "Could not write the combined PDF": "تعذّر حفظ PDF المدموج", "The macOS PDF compression filter is unavailable": "مرشح ضغط PDF غير متاح في النظام",
    "The document could not be printed as PDF": "تعذّر تحويل المستند إلى PDF",
    # Conversions
    "To PDF": "إلى PDF", "To Word": "إلى Word", "To PowerPoint": "إلى PowerPoint", "To EPUB": "إلى EPUB",
    "To Markdown": "إلى Markdown", "To Text": "إلى نص", "To Pages": "إلى Pages", "Extract": "فك الضغط",
    "Archive": "أرشيف", "The source archive is empty.": "الأرشيف فارغ.",
    "This RAR archive is encrypted or uses a format the Mac cannot open.": "أرشيف RAR هذا مشفّر أو بصيغة لا يفتحها الماك.",
    "The EPUB does not identify a readable package document.": "ملف EPUB غير صالح للقراءة.", "The EPUB has no readable chapters.": "لا يحتوي EPUB على فصول قابلة للقراءة.",
    "The clipping contains no supported text.": "لا تحتوي القصاصة على نص مدعوم.",
    "This text clipping has an unsupported or malformed format.": "قصاصة النص هذه بصيغة غير مدعومة.",
    "Could not encode the image": "تعذّر ترميز الصورة",
    # QR generator
    "Create QR Code": "إنشاء رمز QR", "Make QR": "صنع QR", "Text or Link": "نص أو رابط", "Wi-Fi": "Wi-Fi",
    "Network name": "اسم الشبكة", "Password": "كلمة المرور", "Security": "الحماية", "None": "بدون",
    "WPA / WPA2 / WPA3": "WPA / WPA2 / WPA3", "WEP": "WEP", "Hidden network": "شبكة مخفية", "Squares": "مربعات",
    "Dots": "نقاط", "Colors": "الألوان", "Code color": "لون الرمز", "Transparent background": "خلفية شفافة",
    "Margin": "الهامش", "Error correction": "تصحيح الأخطاء", "Low · 7%": "منخفض · 7%", "Medium · 15%": "متوسط · 15%",
    "Quartile · 25%": "عالٍ · 25%", "High · 30%": "الأعلى · 30%", "Copy Image": "نسخ الصورة", "Save QR Code": "حفظ رمز QR",
    "QR code copied": "نُسخ رمز QR", "Type the text or link to encode.": "اكتب النص أو الرابط.",
    "Enter the network name.": "اكتب اسم الشبكة.",
    "This is too long for a QR code. Shorten it or lower the error correction.": "النص طويل على رمز QR. اختصره أو قلّل تصحيح الأخطاء.",
    "Rounded": "مستدير", "Diamonds": "معيّنات", "Fluid": "انسيابي", "Bars": "أعمدة", "Square": "مربع", "Circle": "دائرة",
    "Leaf": "ورقة", "Shape": "الشكل", "Corners": "الزوايا", "Gradient end": "نهاية التدرج", "Gradient": "تدرج",
    "Own corner color": "لون خاص للزوايا", "Corner color": "لون الزوايا", "Transparent": "شفافة", "Logo": "الشعار",
    "Remove": "إزالة", "Choose Logo…": "اختر شعارًا…", "Change…": "تغيير…", "Logo size": "حجم الشعار",
    "Behind the logo": "خلف الشعار", "Or drop an image on the preview.": "أو أفلت صورة على المعاينة.",
    "Checking…": "جارٍ الفحص…", "Scans correctly": "يُقرأ بشكل سليم",
    "May not scan. Use a smaller logo, more contrast or higher correction.": "قد لا يُقرأ. صغّر الشعار أو زوّد التباين أو ارفع تصحيح الأخطاء.",
    "Choose a logo for the middle of the code": "اختر شعارًا لمنتصف الرمز",
    "little to gain": "التوفير قليل",
}

# Text with values. {1}, {2}… are the values, in order of appearance in the English.
DYNAMIC = {
    "Adding background {1} of {2}": "جارٍ إضافة الخلفية {1} من {2}",
    "Allow Adawat to control {1} in System Settings › Privacy & Security › Automation.": "اسمح لتطبيق أدوات بالتحكم في {1} من إعدادات النظام › الخصوصية والأمان › الأتمتة.",
    "Audio keeps its pitch. The new length is {1}.": "يحتفظ الصوت بطبقته. المدة الجديدة {1}.",
    "Box {1}": "مربع {1}", "Building slide {1} of {2}": "جارٍ بناء الشريحة {1} من {2}",
    "Compressed PDF · {1}% smaller": "ضُغط PDF · أصغر بنسبة {1}%", "Compressed {1}": "ضُغط {1}",
    "Compressed {1} · {2}% smaller": "ضُغط {1} · أصغر بنسبة {2}%", "Compressed {1} · already as small as it gets": "ضُغط {1} · صغير بالفعل",
    "Compressing {1} of {2}": "جارٍ الضغط {1} من {2}", "Converting {1}": "جارٍ تحويل {1}", "Converting {1} of {2}": "جارٍ التحويل {1} من {2}",
    "Converting {1} of {2} to {3}": "جارٍ التحويل {1} من {2} إلى {3}", "Converting {1} of {2} with Keynote": "جارٍ التحويل {1} من {2} عبر Keynote",
    "Copied: {1}": "نُسخ: {1}", "Could not change login item: {1}": "تعذّر تغيير عنصر الدخول: {1}",
    "Could not decode {1}": "تعذّر فك ترميز {1}", "Could not fit {1} within {2}. Choose a larger size.": "تعذّر ضغط {1} إلى {2}. اختر حجمًا أكبر.",
    "Could not play the preview. {1}": "تعذّر تشغيل المعاينة. {1}", "Could not prepare {1} for cutting": "تعذّر تجهيز {1} للقص",
    "Could not prepare {1} for rotation": "تعذّر تجهيز {1} للتدوير",
    "Could not reach the target size. Smallest attempt was {1}.": "تعذّر الوصول إلى الحجم المطلوب. أصغر محاولة كانت {1}.",
    "Could not read {1}": "تعذّرت قراءة {1}", "Could not render page {1}": "تعذّر عرض الصفحة {1}", "Could not rotate {1}": "تعذّر تدوير {1}",
    "Could not save {1}": "تعذّر حفظ {1}", "Could not save the metadata: {1}": "تعذّر حفظ البيانات: {1}",
    "Couldn't read a frame from {1}": "تعذّرت قراءة إطار من {1}", "Couldn't read the length of {1}": "تعذّرت قراءة مدة {1}",
    "Cropping {1} of {2}": "جارٍ القص {1} من {2}", "Cutting clip {1} of {2}": "جارٍ قص المقطع {1} من {2}",
    "Drag files, then press {1} {2} {3}": "اسحب الملفات ثم اضغط {1} {2} {3}", "Encoding {1} videos into one": "جارٍ دمج {1} فيديوهات في فيديو واحد",
    "Extracting {1}": "جارٍ فك ضغط {1}", "FLOAT · {1}": "FLOAT · {1}", "Fitting {1} of {2} to the target size": "جارٍ ضبط {1} من {2} على الحجم المطلوب",
    "Joining {1} videos": "جارٍ دمج {1} فيديوهات", "Joining {1} clips": "جارٍ دمج {1} مقاطع",
    "Measuring loudness {1} of {2}": "جارٍ قياس الصوت {1} من {2}", "Merged {1} PDFs · {2} pages": "دُمج {1} ملفات PDF · {2} صفحة",
    "No valid subtitle cues were found in {1}.": "لا توجد ترجمة صالحة في {1}.", "Normalizing {1} of {2}": "جارٍ التوحيد {1} من {2}",
    "Now: {1} LUFS · peak {2} dBTP · range {3} LU": "الآن: {1} LUFS · الذروة {2} dBTP · المدى {3} LU",
    "Opened Terminal in {1}": "فُتح Terminal في {1}", "Original size: {1}": "الحجم الأصلي: {1}", "Page {1} of {2}": "الصفحة {1} من {2}",
    "Pages to {1}": "الصفحات إلى {1}", "Reading text {1} of {2}": "جارٍ قراءة النص {1} من {2}",
    "Recognizing page {1} of {2}": "جارٍ التعرف على الصفحة {1} من {2}", "Rendering page {1} of {2}": "جارٍ عرض الصفحة {1} من {2}",
    "Reset {1}": "إعادة ضبط {1}", "Resizing {1} of {2}": "جارٍ تغيير الحجم {1} من {2}", "Save {1} Frames": "حفظ {1} لقطات",
    "Saved {1} files": "حُفظت {1} ملفات", "Saved {1}": "حُفظ {1}", "Saving clip {1} of {2}": "جارٍ حفظ المقطع {1} من {2}",
    "The same background is added to all {1} images.": "تُضاف نفس الخلفية إلى كل الصور ({1}).",
    "This Mac cannot write {1} images": "لا يستطيع هذا الماك إنشاء صور {1}", "To {1}": "إلى {1}",
    "Uses this crop, as the same share of each image, for all {1} images.": "يُطبَّق هذا القص بالنسبة نفسها على كل الصور ({1}).",
    "{1} px": "{1} بكسل", "{1} px longest edge": "{1} بكسل لأطول ضلع",
    "{1} selected": "{1} محدد", "{1} could not convert {2}.": "تعذّر على {1} تحويل {2}.",
    "{1} finished without creating {2}.": "انتهى {1} دون إنشاء {2}.",
    "{1} is needed for {2} files. It is free in the App Store.": "يلزم تطبيق {1} لملفات {2}، وهو مجاني في App Store.",
    "{1} failed: {2}": "فشل {1}: {2}", "{1} has no audio track": "لا يحتوي {1} على صوت",
    "{1} has no selectable text. Use Copy Text to read scanned pages.": "لا يحتوي {1} على نص قابل للتحديد. استخدم «نسخ النص» لقراءة الصفحات الممسوحة.",
    "{1} has no video track": "لا يحتوي {1} على فيديو", "{1} is empty.": "{1} فارغ.", "{1} files": "{1} ملفات",
    "{1} files copied": "نُسخت {1} ملفات", "{1} paths copied": "نُسخت {1} مسارات", "{1} done": "تم: {1}",
    "{1} is not installed. Install it with: brew install {2}": "{1} غير مثبّت. ثبّته بالأمر: brew install {2}",
    "{1} cannot be read or is password-protected": "تعذّرت قراءة {1} أو أنه محمي بكلمة مرور",
    "{1} could not be read as a document": "تعذّرت قراءة {1} كمستند", "{1} has no pages": "لا يحتوي {1} على صفحات",
    "{1} has no readable sheet.": "لا يحتوي {1} على جدول قابل للقراءة.", "{1} is not a spreadsheet.": "{1} ليس جدولًا.",
    "{1} is not readable text.": "{1} ليس نصًا قابلًا للقراءة.", "{1} is password-protected": "{1} محمي بكلمة مرور",
    "{1}. Double-click to open; drag to carry the file.": "{1}. انقر مرتين للفتح، واسحب لنقل الملف.",
    "Metadata removed from {1} image": "حُذفت البيانات من صورة واحدة", "Metadata removed from {1} images": "حُذفت البيانات من {1} صور",
    "Metadata removed from {1} file": "حُذفت البيانات من ملف واحد", "Metadata removed from {1} files": "حُذفت البيانات من {1} ملفات",
    "Metadata removed from {1} PDF": "حُذفت البيانات من ملف PDF", "Metadata removed from {1} PDFs": "حُذفت البيانات من {1} ملفات PDF",
    "Moved {1} item to {2}": "نُقل عنصر واحد إلى {2}", "Moved {1} items to {2}": "نُقلت {1} عناصر إلى {2}",
    "Saved {1} clip": "حُفظ مقطع واحد", "Saved {1} clips": "حُفظت {1} مقاطع",
    "Compressing {1} item": "جارٍ ضغط عنصر واحد", "Compressing {1} items": "جارٍ ضغط {1} عناصر",
    "Creating PDF from {1} image": "جارٍ إنشاء PDF من صورة", "Creating PDF from {1} images": "جارٍ إنشاء PDF من {1} صور",
    "{1} image": "صورة واحدة", "{1} images": "{1} صور", "{1} video": "فيديو واحد", "{1} videos": "{1} فيديوهات",
    "{1} file": "ملف واحد", "{1} page": "صفحة واحدة", "{1} pages": "{1} صفحات", "{1} split point": "نقطة تقسيم واحدة",
    "{1} split points": "{1} نقاط تقسيم", "Covered {1} face": "غُطي وجه واحد", "Covered {1} faces": "غُطيت {1} وجوه",
    "Covered {1} text area": "غُطيت منطقة نص واحدة", "Covered {1} text areas": "غُطيت {1} مناطق نص",
    "Choose where to move {1}": "اختر مكان نقل {1}", "{1} × {2} modules": "{1} × {2} وحدة", "{1} items": "{1} عناصر",
}

# Text only the Windows app shows.
WINDOWS_STATIC = {
    "Ctrl": "Ctrl", "Alt": "Alt", "Windows": "Windows", "File Explorer": "مستكشف الملفات",
    "Show in File Explorer": "إظهار في مستكشف الملفات", "Shown in File Explorer": "ظهر في مستكشف الملفات",
    "Share": "مشاركة", "Sharing": "جارٍ المشاركة", "Open in Terminal": "فتح في Terminal",
    "Start Adawat when Windows starts": "تشغيل أدوات مع بدء Windows",
    "Adawat lives next to the clock, so it is ready whenever you drag a file.": "تطبيق أدوات يعيش بجانب الساعة، فهو جاهز كلما سحبت ملفًا.",
    "Find the Adawat icon next to the clock for Floats, Settings and this guide.": "ستجد أيقونة أدوات بجانب الساعة، ومنها الـ Floats والإعدادات وهذا الدليل.",
    "Microsoft Word is needed for this file.": "يلزم Microsoft Word لهذا الملف.",
    "Microsoft PowerPoint is needed for this file.": "يلزم Microsoft PowerPoint لهذا الملف.",
    "Microsoft Excel is needed for this file.": "يلزم Microsoft Excel لهذا الملف.",
    "Pages, Keynote and Numbers files are not supported on Windows.": "ملفات Pages و Keynote و Numbers غير مدعومة على Windows.",
    "Exit": "خروج", "Exit Adawat": "إنهاء أدوات",
    "Convert, compress and edit any file while you drag it. Everything stays on your PC.": "حوّل واضغط وعدّل أي ملف وأنت تسحبه. كل شيء يتم على جهازك.",
    "Something went wrong: ": "حدث خطأ: ", "Create QR Code…": "إنشاء رمز QR…",
    "Move up": "تحريك لأعلى", "Move down": "تحريك لأسفل", "Fewer": "أقل", "More": "أكثر",
    "Paste an image with Ctrl+V or choose one. Drag it to move.": "الصق صورة بـ Ctrl+V أو اخترها. اسحبها لتحريكها.",
    "Could not play the preview. ": "تعذّر تشغيل المعاينة. ",
    # Updates (Windows and Linux)
    "Check for Updates": "التحقق من التحديثات", "Checking for updates": "جارٍ التحقق من التحديثات",
    "Check for updates when Adawat starts": "التحقق من التحديثات عند تشغيل أدوات", "Updates": "التحديثات", "Check Now": "تحقق الآن",
    "Could not check for updates. Check your internet connection.": "تعذّر التحقق من التحديثات. تأكد من اتصالك بالإنترنت.",
    "Update Adawat": "تحديث أدوات", "Your settings and files stay as they are.": "تبقى إعداداتك وملفاتك كما هي.",
    "What's new": "الجديد", "Skip This Version": "تخطَّ هذا الإصدار", "Later": "لاحقًا", "Update Now": "حدّث الآن",
    "Downloading the update": "جارٍ تنزيل التحديث",
    "The update did not download correctly. Try again later.": "لم يُنزَّل التحديث بشكل صحيح. حاول مرة أخرى لاحقًا.",
    "Could not download the update. Check your internet connection.": "تعذّر تنزيل التحديث. تأكد من اتصالك بالإنترنت.",
    "Install the downloaded package to finish the update": "ثبّت الحزمة التي نُزّلت لإكمال التحديث",
    "Adawat cannot replace itself in this folder. Download the new version from GitHub.": "لا يستطيع أدوات استبدال نفسه في هذا المجلد. نزّل الإصدار الجديد من GitHub.",
}
WINDOWS_DYNAMIC = {
    "Drag files, then press {1}, {2} or {3}": "اسحب الملفات ثم اضغط {1} أو {2} أو {3}",
    "Adawat {1} is available": "الإصدار {1} من أدوات متاح",
    "Adawat {1} is available. You have {2}.": "الإصدار {1} من أدوات متاح. لديك الإصدار {2}.",
    "Adawat {1} is the latest version": "لديك أحدث إصدار من أدوات ({1})",
}

# Text only the Linux app shows (it reads the same JSON as the Windows app).
LINUX_STATIC = {
    "Convert, compress and edit any file while you drag it. Everything stays on your computer.": "حوّل واضغط وعدّل أي ملف وأنت تسحبه. كل شيء يتم على جهازك.",
    "Start Adawat when you sign in": "تشغيل أدوات عند تسجيل الدخول",
    "Adawat lives in the top bar, so it is ready whenever you drag a file.": "تطبيق أدوات يعيش في الشريط العلوي، فهو جاهز كلما سحبت ملفًا.",
    "Find the Adawat icon in the top bar for Floats, Settings and this guide.": "ستجد أيقونة أدوات في الشريط العلوي، ومنها الـ Floats والإعدادات وهذا الدليل.",
    "Sign out and back in once so GNOME loads the Adawat extension. Until then, right-click files and choose Open with Adawat.":
        "سجّل الخروج ثم الدخول مرة واحدة ليحمّل GNOME إضافة أدوات. حتى ذلك الحين، انقر الملفات بالزر الأيمن واختر «فتح بأدوات».",
    "The Adawat extension for GNOME is missing. Right-click files and choose Open with Adawat to open the wheel.":
        "إضافة أدوات لـ GNOME غير موجودة. انقر الملفات بالزر الأيمن واختر «فتح بأدوات» لتظهر العجلة.",
    "On this desktop the wheel opens from the file manager: right-click files and choose Open with Adawat.":
        "على سطح المكتب هذا تظهر العجلة من مدير الملفات: انقر الملفات بالزر الأيمن واختر «فتح بأدوات».",
    "Open with Adawat": "فتح بأدوات", "Show in Files": "إظهار في الملفات", "Float": "Float", "Search": "بحث",
    "Choose an image": "اختر صورة", "Cancel": "إلغاء", "Copy": "نسخ", "Email": "بريد إلكتروني", "Attach to a new message": "إرفاق برسالة جديدة",
    "Bluetooth": "Bluetooth", "Send to a nearby device": "إرسال إلى جهاز قريب", "KDE Connect": "KDE Connect",
    "Send to your phone": "إرسال إلى هاتفك", "Paste the files in any app": "ألصق الملفات في أي تطبيق",
    "No phone is connected to KDE Connect": "لا يوجد هاتف متصل بـ KDE Connect", "Sent to your phone": "أُرسل إلى هاتفك",
    "No terminal app was found.": "لم يُعثر على تطبيق طرفية.",
    "LibreOffice is needed for this file.": "يلزم LibreOffice لهذا الملف.",
    "The face detector is missing from this installation.": "كاشف الوجوه غير موجود في هذا التثبيت.",
    "No audio player was found (pw-play or paplay).": "لم يُعثر على مشغّل صوت (pw-play أو paplay).",
}
LINUX_DYNAMIC = {
    "Text recognition failed: {1}": "تعذّرت قراءة النص: {1}",
    "{1} is not installed. Install it with: {2}": "{1} غير مثبّت. ثبّته بالأمر: {2}",
    "Text recognition needs Tesseract. Install it with: {1}": "قراءة النص تحتاج Tesseract. ثبّته بالأمر: {1}",
    "Making PDFs needs WeasyPrint. Install it with: {1}": "إنشاء ملفات PDF يحتاج WeasyPrint. ثبّته بالأمر: {1}",
    "Rich Text needs LibreOffice. Install it with: {1}": "ملفات RTF تحتاج LibreOffice. ثبّته بالأمر: {1}",
    "LibreOffice is needed for this file. Install it with: {1}": "يلزم LibreOffice لهذا الملف. ثبّته بالأمر: {1}",
    "Copying needs xclip or wl-clipboard. Install it with: {1}": "النسخ يحتاج xclip أو wl-clipboard. ثبّته بالأمر: {1}",
    "LibreOffice could not convert {1}.": "تعذّر على LibreOffice تحويل {1}.",
}


def regex(english):
    """'Converting {1} of {2}' → 'Converting (.+?) of (.+?)' with everything else matched literally."""
    parts = re.split(r"\{\d\}", english)
    return "(.+?)".join(re.escape(part) for part in parts)


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    root = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "ar.lproj"
    root.mkdir(parents=True, exist_ok=True)
    static = "".join(f'"{escape(k)}" = "{escape(v)}";\n' for k, v in sorted(STATIC.items()))
    (root / "Localizable.strings").write_text(static, encoding="utf-8")
    def template(arabic):
        return re.sub(r"\{(\d)\}", lambda m: "\\" + m.group(1), arabic)
    patterns = "".join(f'"{escape(regex(k))}" = "{escape(template(v))}";\n' for k, v in sorted(DYNAMIC.items()))
    (root / "Patterns.strings").write_text(patterns, encoding="utf-8")
    # The app's own name in Finder, the Dock and Launchpad.
    (root / "InfoPlist.strings").write_text('"CFBundleDisplayName" = "أدوات";\n"CFBundleName" = "أدوات";\n', encoding="utf-8")
    # The Windows and Linux apps read the same translations as JSON; {1}, {2}… stay as written.
    import json
    shared = root.parent.parent / "windows" / "shared"
    if shared.parent.exists():
        shared.mkdir(exist_ok=True)
        merged = {**STATIC, **WINDOWS_STATIC, **LINUX_STATIC}
        (shared / "strings.ar.json").write_text(json.dumps(merged, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
        (shared / "patterns.ar.json").write_text(json.dumps({**DYNAMIC, **WINDOWS_DYNAMIC, **LINUX_DYNAMIC}, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"{len(STATIC)} strings, {len(DYNAMIC)} patterns")


if __name__ == "__main__":
    main()
