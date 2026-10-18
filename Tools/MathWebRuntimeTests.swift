import AppKit
import WebKit
import SwiftUI

@main
struct MathWebRuntimeTests {
    static var checks = 0
    static var failures = 0
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MINOTE_TEST_OUTPUT"] ?? FileManager.default.currentDirectoryPath + "/outputs", isDirectory: true)
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { await run(); print("RUNTIME: \(checks) assertions, \(failures) failures"); exit(failures == 0 ? 0 : 1) }
        NSApplication.shared.run()
    }
    static func check(_ condition: Bool, _ name: String) { checks += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") \(name)") }
    @MainActor static func loaded(_ html: String, width: CGFloat = 650, dark: Bool = false) async throws -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 400), configuration: config)
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        web.loadHTMLString(document(html), baseURL: nil)
        for _ in 0..<400 {
            if let ready = try? await web.evaluateJavaScript("window.__mathSettled === true") as? Bool, ready { return web }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(domain: "MathTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit readiness timeout"])
    }
    static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data:;">
        \(MathWebDocument.head())<style>
        :root{color-scheme:light dark}body{font:16px -apple-system;margin:16px;color:#222;background:#fff;}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#202124;}}
        .mn-table-scroll{max-width:100%;overflow:auto}table{border-collapse:collapse;width:100%}th,td{border:1px solid #8888;padding:10px;text-align:left}
        pre{background:#8882;padding:10px;overflow:auto}svg{max-width:100%;height:auto}
        </style></head><body>\(body)</body></html>
        """
    }
    @MainActor static func run() async {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await ImportPipelineTests.run()
            let galleryJSON = [
                #"{"type":"area","title":"面积图 · 合成月度数据","xLabel":"月份","yLabel":"数量","data":[{"label":"一月","value":3},{"label":"二月","value":8},{"label":"三月","value":6},{"label":"四月","value":12},{"label":"五月","value":9}]}"#,
                #"{"type":"scatter","title":"散点图 · 合成观测数据","xLabel":"时长","yLabel":"得分","series":[{"label":"A 组","data":[{"x":1,"y":2},{"x":2,"y":5},{"x":3,"y":4},{"x":6,"y":8},{"x":8,"y":7}]},{"label":"B 组","data":[{"x":1,"y":4},{"x":2,"y":3},{"x":4,"y":7},{"x":6,"y":5},{"x":9,"y":9}]}]}"#,
                #"{"type":"radar","title":"雷达图 · 合成评分对比","unit":"分","yMax":100,"series":[{"label":"方案 A","data":[{"label":"速度","value":85},{"label":"质量","value":90},{"label":"稳定性","value":65},{"label":"成本控制","value":55},{"label":"易用性","value":80}]},{"label":"方案 B","data":[{"label":"速度","value":60},{"label":"质量","value":70},{"label":"稳定性","value":90},{"label":"成本控制","value":85},{"label":"易用性","value":65}]}]}"#,
                #"{"type":"histogram","title":"直方图 · 合成测量分布","xLabel":"观测值","samples":[1,2,2,3,3,3,4,4,4,4,5,5,5,5,5,6,6,6,6,7,7,7,8,8,9],"bins":8}"#
            ]
            let gallerySource = galleryJSON.map { "```chart\n" + $0 + "\n```" }.joined(separator: "\n\n")
            let galleryHTML = AITextToHTML.render(gallerySource)
            let galleryWeb = try await loaded(galleryHTML)
            check(try await galleryWeb.evaluateJavaScript("document.querySelectorAll('svg').length===4 && document.querySelector('.mn-chart-area').getTotalLength()>500 && document.querySelectorAll('.mn-chart-point').length===15 && document.querySelectorAll('.mn-radar-series').length===2 && document.querySelectorAll('.mn-histogram-bin').length===8") as? Bool == true, "four new chart types draw actual SVG geometry in WebKit")
            check(try await galleryWeb.evaluateJavaScript("Array.from(document.querySelectorAll('.mn-histogram-bin')).reduce((n,b)=>n+Number(b.dataset.count),0)===25") as? Bool == true, "histogram bin counts preserve every raw observation")
            check(try await galleryWeb.evaluateJavaScript("(()=>{const s=document.querySelector('svg');const labels=Array.from(s.querySelectorAll('text'));const month=labels.find(t=>t.textContent==='三月');const axis=labels.find(t=>t.textContent==='月份');return axis.getBBox().y>month.getBBox().y+month.getBBox().height && !labels.some(t=>t.textContent==='0.8');})()") as? Bool == true, "categorical area axis uses month labels without numeric or title overlap")
            let gallerySaved = try await galleryWeb.evaluateJavaScript("window.MiNoteMath.canonicalHTML()") as? String ?? ""
            let galleryReopened = try await loaded(gallerySaved)
            check(try await galleryReopened.evaluateJavaScript("document.querySelectorAll('svg').length===4 && document.querySelectorAll('.mn-radar-series').length===2 && document.querySelector('.mn-chart-area').getAttribute('d').includes('Z')") as? Bool == true, "new charts survive editor save and reopen")
            for dark in [false,true] {
                let smallGallery = try await loaded(galleryHTML,width:300,dark:dark)
                check(try await smallGallery.evaluateJavaScript("Array.from(document.querySelectorAll('svg')).every(s=>s.getBoundingClientRect().width<=document.body.clientWidth && getComputedStyle(s).color===getComputedStyle(document.body).color)") as? Bool == true, "new charts fit narrow layout and inherit theme \(dark)")
            }
            let galleryExport = try await MathImageRenderer.exportHTML(gallerySaved)
            let galleryAttachments = try NoteExportHTML.attachInlineImages(galleryExport)
            let galleryENML = XiaomiConvert.sanitizeToENML(galleryAttachments.html,imageMeta:galleryAttachments.imageMeta)
            check(!galleryExport.contains("<svg") && galleryAttachments.resources.count==4 && galleryENML.components(separatedBy:"<en-media").count-1==4, "all four charts export as PNG attachments in ENEX")
            check(galleryAttachments.resources.allSatisfy { galleryENML.contains($0.md5) }, "new chart PNG resource hashes match ENML references")
            for (index, resource) in galleryAttachments.resources.enumerated() {
                try resource.data.write(to:root.appendingPathComponent("chart-gallery-\(index).png"))
                if let bitmap=NSBitmapImageRep(data:resource.data) {
                    var colored=0
                    for y in stride(from:0,to:bitmap.pixelsHigh,by:6) {
                        for x in stride(from:0,to:bitmap.pixelsWide,by:6) {
                            if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), max(c.redComponent,c.greenComponent,c.blueComponent)-min(c.redComponent,c.greenComponent,c.blueComponent)>0.15 {colored+=1}
                        }
                    }
                    check(colored>25,"new chart PNG contains visible data pixels \(index)")
                } else {check(false,"new chart PNG decodes \(index)")}
            }
            try document(galleryHTML).write(to:root.appendingPathComponent("chart-gallery.html"),atomically:true,encoding:.utf8)
            let surfaceSource = #"""
            ```chart
            {"type":"surface","title":"马鞍面 z=x²−y²","expression":"x^2-y^2","xMin":-2,"xMax":2,"yMin":-2,"yMax":2}
            ```
            """#
            let surfaceHTML = AITextToHTML.render(surfaceSource)
            let surfaceWeb = try await loaded(surfaceHTML)
            check(try await surfaceWeb.evaluateJavaScript("!!window.MiNoteSurface && document.querySelectorAll('.mn-surface-faces polygon').length>1000 && document.querySelectorAll('.mn-surface-axes text').length===12") as? Bool == true, "3D surface renders visible mesh and numeric axes in WebKit")
            let originalSurfacePoints = try await surfaceWeb.evaluateJavaScript("document.querySelector('.mn-surface-faces polygon').getAttribute('points')") as? String
            _ = try await surfaceWeb.evaluateJavaScript("document.querySelector('.mn-surface-chart').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));true")
            check(try await surfaceWeb.evaluateJavaScript("Math.abs(Number(document.querySelector('.mn-surface-chart').getAttribute('data-yaw'))+0.6)<1e-9") as? Bool == true, "3D keyboard rotation changes view angle")
            let rotatedSurfacePoints = try await surfaceWeb.evaluateJavaScript("document.querySelector('.mn-surface-faces polygon').getAttribute('points')") as? String
            check(originalSurfacePoints != rotatedSurfacePoints, "rotation reprojects actual mesh geometry")
            _ = try await surfaceWeb.evaluateJavaScript("const s=document.querySelector('.mn-surface-chart');s.dispatchEvent(new PointerEvent('pointerdown',{pointerId:1,button:0,clientX:100,clientY:100}));s.dispatchEvent(new PointerEvent('pointermove',{pointerId:1,clientX:130,clientY:110}));s.dispatchEvent(new PointerEvent('pointerup',{pointerId:1}));true")
            check(try await surfaceWeb.evaluateJavaScript("Math.abs(Number(document.querySelector('.mn-surface-chart').getAttribute('data-yaw'))+0.24)<1e-9") as? Bool == true, "pointer drag rotates 3D mesh")
            _ = try await surfaceWeb.evaluateJavaScript("document.querySelector('.mn-surface-chart').dispatchEvent(new WheelEvent('wheel',{deltaY:-80,cancelable:true}));true")
            check(try await surfaceWeb.evaluateJavaScript("Number(document.querySelector('.mn-surface-chart').getAttribute('data-zoom'))>1") as? Bool == true, "3D wheel zoom changes projection scale")
            let savedSurface = try await surfaceWeb.evaluateJavaScript("window.MiNoteMath.canonicalHTML()") as? String ?? ""
            check(savedSurface.contains("data-surface=") && !savedSurface.contains("<script"), "3D save retains model and excludes executable scripts")
            let reopenedSurface = try await loaded(savedSurface)
            check(try await reopenedSurface.evaluateJavaScript("Math.abs(Number(document.querySelector('.mn-surface-chart').getAttribute('data-yaw'))+0.24)<1e-9 && document.querySelectorAll('.mn-surface-faces polygon').length>1000") as? Bool == true, "3D save and reopen restores rotated view")
            _ = try await reopenedSurface.evaluateJavaScript("document.querySelector('.mn-surface-chart').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));true")
            check(try await reopenedSurface.evaluateJavaScript("document.querySelector('.mn-surface-chart').getAttribute('data-yaw')==='-0.72' && document.querySelector('.mn-surface-chart').getAttribute('data-zoom')==='1'") as? Bool == true, "3D double click resets camera")
            for dark in [false,true] {
                let smallSurface = try await loaded(surfaceHTML,width:300,dark:dark)
                check(try await smallSurface.evaluateJavaScript("document.querySelector('svg').getBoundingClientRect().width<=document.body.clientWidth && getComputedStyle(document.querySelector('svg')).color===getComputedStyle(document.body).color") as? Bool == true, "3D surface fits narrow layout and theme \(dark)")
            }
            let surfaceExport = try await MathImageRenderer.exportHTML(savedSurface)
            let surfaceAttachments = try NoteExportHTML.attachInlineImages(surfaceExport)
            let surfaceENML = XiaomiConvert.sanitizeToENML(surfaceAttachments.html,imageMeta:surfaceAttachments.imageMeta)
            check(!surfaceExport.contains("<svg") && surfaceAttachments.resources.count==1 && surfaceENML.contains("<en-media"), "3D rotated surface exports as ENEX PNG attachment")
            if let png = surfaceAttachments.resources.first?.data, let bitmap = NSBitmapImageRep(data:png) {
                try png.write(to:root.appendingPathComponent("surface-saddle.png"))
                var colored = 0
                for y in stride(from:0,to:bitmap.pixelsHigh,by:8) {
                    for x in stride(from:0,to:bitmap.pixelsWide,by:8) {
                        if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), max(c.redComponent,c.greenComponent,c.blueComponent)-min(c.redComponent,c.greenComponent,c.blueComponent)>0.2 {colored+=1}
                    }
                }
                check(colored>300,"3D PNG contains filled surface pixels")
            } else {check(false,"3D PNG decodes")}
            try document(surfaceHTML).write(to:root.appendingPathComponent("surface-validation.html"),atomically:true,encoding:.utf8)
            let poleSurface = AITextToHTML.render(#"""
            ```chart
            {"type":"surface","expression":"1/(x-y)","xMin":-2,"xMax":2,"yMin":-2,"yMax":2}
            ```
            """#)
            let poleSurfaceWeb = try await loaded(poleSurface)
            check(try await poleSurfaceWeb.evaluateJavaScript("(()=>{const m=JSON.parse(atob(document.querySelector('[data-surface]').getAttribute('data-surface')));return m.heights.some(z=>z===null)&&m.triangles.every(t=>{const a=t.map(i=>i%(m.size+1)-Math.floor(i/(m.size+1)));return a.every(x=>x>0)||a.every(x=>x<0);});})()") as? Bool == true, "3D singularity keeps a hole and never bridges opposite sides")
            let curveSource = #"""
            ```chart
            {"type":"function","title":"正弦与余弦","xMin":-6.28,"xMax":6.28,"xLabel":"x（弧度）","yLabel":"y","series":[{"label":"sin(x)","expression":"sin(x)"},{"label":"cos(x)","expression":"cos(x)"}]}
            ```
            """#
            let curveHTML = AITextToHTML.render(curveSource)
            let curveWeb = try await loaded(curveHTML)
            check(try await curveWeb.evaluateJavaScript("document.querySelectorAll('svg.mn-cartesian-chart').length===1 && document.querySelectorAll('.mn-chart-curve').length===2 && document.querySelector('.mn-chart-curve').getTotalLength()>500") as? Bool == true, "actual WebKit draws two nonempty function curves")
            let curveSaved = try await curveWeb.evaluateJavaScript("window.MiNoteMath.canonicalHTML()") as? String ?? ""
            let curveReopened = try await loaded(curveSaved)
            check(try await curveReopened.evaluateJavaScript("document.querySelectorAll('.mn-chart-curve').length===2") as? Bool == true, "curve survives save and reopen")
            for dark in [false, true] {
                let narrowCurve = try await loaded(curveHTML, width: 300, dark: dark)
                check(try await narrowCurve.evaluateJavaScript("document.querySelector('svg').getBoundingClientRect().width <= document.body.clientWidth && getComputedStyle(document.querySelector('svg')).color === getComputedStyle(document.body).color") as? Bool == true, "curve fits narrow layout and inherits theme \(dark)")
            }
            let poleHTML = AITextToHTML.render(#"""
            ```chart
            {"type":"function","title":"倒数函数","expression":"1/x","xMin":-2,"xMax":2}
            ```
            """#)
            let poleWeb = try await loaded(poleHTML)
            check(try await poleWeb.evaluateJavaScript("document.querySelector('.mn-chart-curve').getAttribute('d').split('M').length===3") as? Bool == true, "reciprocal branches are disconnected across the pole")
            let curveExport = try await MathImageRenderer.exportHTML(curveHTML + poleHTML)
            check(!curveExport.contains("<svg") && curveExport.components(separatedBy: "data:image/png;base64,").count - 1 == 2, "curve export produces PNG images instead of dropping SVG")
            let curveAttachments = try NoteExportHTML.attachInlineImages(curveExport)
            let curveENML = XiaomiConvert.sanitizeToENML(curveAttachments.html, imageMeta: curveAttachments.imageMeta)
            check(curveAttachments.resources.count == 2 && curveENML.components(separatedBy: "<en-media").count - 1 == 2, "both curve PNGs survive ENEX conversion")
            for (index, resource) in curveAttachments.resources.enumerated() {
                try resource.data.write(to: root.appendingPathComponent("curve-\(index).png"))
                let bitmap = NSBitmapImageRep(data: resource.data)
                var coloredPixels = 0
                if let bitmap {
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.2 { coloredPixels += 1 }
                        }
                    }
                }
                check(coloredPixels > 40, "exported PNG contains visible colored curve pixels \(index)")
            }
            let p = #"\int_1^{+\infty}\frac{dx}{x^p}\begin{cases}p>1&\text{收敛}\\p\le 1&\text{发散}\end{cases}"#
            let aligned = #"\begin{aligned}a&=b+c\\d&=e+f\end{aligned}"#
            let fraction = #"\frac{a+b}{c+d}"#
            let cases = [fraction, p, aligned, #"a<b\quad c>d\quad\text{中文}"#, "\\frac{1}{2}\n\n+\\frac{3}{4}"]
            for (index, source) in cases.enumerated() {
                let node = MathMarkup.node(latex: source, display: true)
                let web = try await loaded(node)
                let ready = try await web.evaluateJavaScript("window.__mathReady === true && document.querySelectorAll('.katex').length === 1") as? Bool
                check(ready == true, "real KaTeX formula \(index)")
                let original = try await web.evaluateJavaScript("document.querySelector('[data-latex]').getAttribute('data-latex')") as? String
                check(original == Data(source.utf8).base64EncodedString(), "source bytes unchanged \(index)")
                let canonical = try await web.evaluateJavaScript("window.MiNoteMath.canonicalHTML()") as? String ?? ""
                check(!canonical.contains("katex-html") && !canonical.contains("<script"), "save excludes generated DOM \(index)")
                let reopened = try await loaded(canonical)
                check(try await reopened.evaluateJavaScript("window.__mathReady === true && document.querySelectorAll('.katex').length === 1") as? Bool == true, "save and reopen \(index)")
                if index == 0 { check(try await web.evaluateJavaScript("document.querySelectorAll('mfrac').length === 1") as? Bool == true, "fraction is mfrac not text") }
                if index == 1 { check(try await web.evaluateJavaScript("document.querySelector('.katex-mathml').textContent.includes('∫')") as? Bool == true, "integral sign retained") }
            }
            let bad = try await loaded(MathMarkup.node(latex: #"\unknownMiNoteCommand{x}"#, display: true))
            check(try await bad.evaluateJavaScript("window.__mathReady === false && window.__mathErrors.length === 1 && !!document.querySelector('.mn-math-error-button')") as? Bool == true, "invalid formula produces actionable error")
            let badSaved = try await bad.evaluateJavaScript("window.MiNoteMath.canonicalHTML()") as? String ?? ""
            check(badSaved.contains(#"\unknownMiNoteCommand{x}"#) && !badSaved.contains("公式错误"), "failed formula saves original source")
            do { _ = try await MathImageRenderer.renderedImage(#"\unknownMiNoteCommand{x}"#, display: true); check(false, "invalid PNG rejected") } catch { check(true, "invalid PNG rejected") }

            let tableSource = "｜公式｜说明｜\n｜--｜--｜\n｜$|x|$｜绝对值｜\n｜$\\frac{a+b}{c+d}$｜分式｜"
            let tableHTML = AITextToHTML.render(tableSource)
            let table = try await loaded(tableHTML)
            check(try await table.evaluateJavaScript("document.querySelectorAll('table').length===1 && document.querySelectorAll('td').length===4 && document.querySelectorAll('.katex').length===2") as? Bool == true, "fullwidth short separators become real table")
            check(try await table.evaluateJavaScript("!document.body.innerText.includes('｜--｜')") as? Bool == true, "table delimiter never leaks into display")
            let code = try await loaded(AITextToHTML.render("```text\n｜--｜ $x$\n```\n价格 $5 / $10"))
            check(try await code.evaluateJavaScript("document.querySelectorAll('.katex').length===0 && document.querySelector('code').textContent.includes('｜--｜ $x$')") as? Bool == true, "literal code and currency protected")
            for dark in [false, true] {
                let web = try await loaded(MathMarkup.node(latex: fraction, display: true), dark: dark)
                let values = try await web.evaluateJavaScript("[getComputedStyle(document.body).color,getComputedStyle(document.querySelector('.katex')).color,matchMedia('(prefers-color-scheme:dark)').matches]") as? [Any] ?? []
                check(values.count == 3 && values[0] as? String == values[1] as? String && values[2] as? Bool == dark, "theme inherits actual WebKit appearance \(dark ? "dark" : "light")")
            }
            let long = (0..<30).map { "x_{\($0)}" }.joined(separator: "+")
            let narrow = try await loaded(MathMarkup.node(latex: long, display: true), width: 300)
            check(try await narrow.evaluateJavaScript("document.querySelector('.mn-math').scrollWidth > document.querySelector('.mn-math').clientWidth && document.querySelector('.mn-math').getBoundingClientRect().height < 90") as? Bool == true, "long formula scrolls horizontally without fragmentation")

            for (name, source) in [("fraction", fraction), ("integral", p), ("aligned", aligned)] {
                let image = try await MathImageRenderer.renderedImage(source, display: true)
                check(image.size.width > 6 && image.size.height > 6 && image.size.height < 200, "tight visible PNG bounds \(name) \(image.size)")
                try image.pngData.write(to: root.appendingPathComponent("formula-\(name).png"))
            }
            let exported = try await MathImageRenderer.exportHTML(tableHTML)
            check(exported.components(separatedBy: "data:image/png;base64,").count - 1 == 2, "export converts both inline table formulas to images")
            check(!exported.contains("katex-html") && exported.contains("data-latex"), "export excludes generated DOM but retains recovery source")
            let attachment = try NoteExportHTML.attachInlineImages(exported)
            let enml = XiaomiConvert.sanitizeToENML(attachment.html, imageMeta: attachment.imageMeta)
            check(attachment.resources.count == 2 && enml.components(separatedBy: "<en-media").count - 1 == 2, "ENEX sanitizer retains both formula image attachments")
            check(attachment.resources.allSatisfy { resource in enml.contains(resource.md5) }, "ENEX media hashes match actual PNG resources")
            let note = EnexNote(title: "合成公式验收", body: enml, created: Date(), updated: Date(), resources: attachment.resources)
            check(EnexWriter.validate(EnexWriter.render(notes: [note]), expectedNotes: 1).isEmpty, "synthetic export structure validates without touching Apple Notes")
            let exportBack = try await loaded(exported)
            check(try await exportBack.evaluateJavaScript("window.__mathReady && document.querySelectorAll('.katex').length===2") as? Bool == true, "export images with source can rehydrate")

            #if APP_VIEWS
            let legacyTable = "<p>｜公式｜说明｜<br/>｜--｜--｜<br/>｜$|x|$｜绝对值｜</p>"
            check(WebNoteHTMLBridge.repairingLegacyTables(legacyTable).contains("<table>"), "legacy saved table syntax upgrades without recreating content")
            check(WebNoteHTMLBridge.repairingLegacyTables("<p><code>｜--｜</code></p>") == "<p><code>｜--｜</code></p>", "legacy repair does not erase code examples")
            let reported = #"\int_1^{+\infty}\frac{dx}{x^p}\ \begin{cases}p>1\ \text{收敛}\ p\le 1\ \text{发散}\end{cases}\qquad \int_0^{1}\frac{dx}{x^p}\ \begin{cases}p<1\ \text{收敛}\ p\ge 1\ \text{发散}\end{cases}"#
            let reportedWeb = try await loaded(AITextToHTML.render("$$" + reported + "$$"))
            check(try await reportedWeb.evaluateJavaScript("window.__mathReady === true && document.querySelectorAll('mfrac').length===2") as? Bool == true, "exact user formula renders without rewriting its source")
            let realEditor = WKWebView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
            realEditor.loadHTMLString(WebNoteHTMLBridge.fullDocument(tableHTML + curveHTML + surfaceHTML + galleryHTML, editable: true), baseURL: nil)
            for _ in 0..<400 {
                if try await realEditor.evaluateJavaScript("window.__mathSettled === true") as? Bool == true { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            check(try await realEditor.evaluateJavaScript("window.__mathReady && document.querySelectorAll('table').length===1 && document.querySelectorAll('.katex').length===2") as? Bool == true, "actual editor fullDocument renders table and math")
            check(try await realEditor.evaluateJavaScript("document.body.contentEditable==='true' && !window.MiNoteMath.canonicalHTML().includes('<script')") as? Bool == true, "actual editor preserves editability without persisting scripts")
            check(try await realEditor.evaluateJavaScript("document.querySelectorAll('.mn-chart-curve').length===3") as? Bool == true, "actual editor displays function curves and area outline")
            check(try await realEditor.evaluateJavaScript("document.querySelectorAll('.mn-surface-faces polygon').length>1000") as? Bool == true, "actual editor displays 3D surface")
            check(try await realEditor.evaluateJavaScript("document.querySelectorAll('.mn-chart-area').length===1 && document.querySelectorAll('.mn-radar-series').length===2 && document.querySelectorAll('.mn-histogram-bin').length===8 && document.querySelectorAll('.mn-chart-point').length===15") as? Bool == true, "actual editable note displays area scatter radar and histogram")
            check(try await realEditor.evaluateJavaScript("window.__surfaceInput=0;document.addEventListener('input',()=>window.__surfaceInput++);document.querySelector('.mn-surface-chart').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));window.__surfaceInput===1") as? Bool == true, "3D camera changes notify editor autosave")
            let hosting = NSHostingView(rootView: ChatRichContentView(text: tableSource + "\n\n" + curveSource + "\n\n" + surfaceSource + "\n\n" + gallerySource).frame(width: 620))
            let window = NSWindow(contentRect: NSRect(x: -1500, y: -1500, width: 650, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            func webIn(_ view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.compactMap { webIn($0) }.first
            }
            var chatReady = false
            for _ in 0..<400 {
                hosting.layoutSubtreeIfNeeded()
                if let web = webIn(hosting), let ready = try? await web.evaluateJavaScript("window.__mathReady === true && document.querySelectorAll('table').length === 1 && document.querySelectorAll('.mn-chart-curve').length===3 && document.querySelectorAll('.mn-surface-faces polygon').length>1000 && document.querySelectorAll('.mn-radar-series').length===2 && document.querySelectorAll('.mn-histogram-bin').length===8 && document.querySelectorAll('.mn-chart-point').length===15") as? Bool, ready {
                    chatReady = true; check(web.frame.height > 40, "actual chat receives measured height");
                    check((web as? PassthroughWebView)?.containsSurface == true, "actual chat enables native surface scroll routing"); break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            check(chatReady, "actual SwiftUI chat wrapper renders table, curves and 3D surface")
            window.contentView = nil
            #endif

            let preview = AITextToHTML.render("# 公式与表格回归验收\n半角、全角与短分隔符转为真实表格；以下内容只使用合成数据。\n\n" + tableSource + "\n\n## p 积分与多行结构\n$$" + p + "$$\n\n$$" + aligned + "$$\n\n## 代码不误删\n```text\n｜--｜ $x$\n```\n\n## 长公式横向滚动\n$$" + long + "$$")
            try document(preview).write(to: root.appendingPathComponent("rendering-validation.html"), atomically: true, encoding: .utf8)
            try document(curveHTML + poleHTML).write(to: root.appendingPathComponent("curve-validation.html"), atomically: true, encoding: .utf8)
        } catch { failures += 1; print("RUNTIME ERROR: \(error)") }
    }
}
