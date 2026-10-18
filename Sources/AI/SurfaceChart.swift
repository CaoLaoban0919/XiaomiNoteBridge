import Foundation

/// z=f(x,y) 的离线网格。保留可见 SVG 与采样数据，保存、重开和导出共用。
enum SurfaceChart {
    private struct Model: Encodable {
        let size: Int
        let heights: [Double?]
        let triangles: [[Int]]
        let ranges: [Double]
        let labels: [String]
        let expression: String
    }
    private struct Vertex { let x: Double; let y: Double; let z: Double }
    private struct Face { let vertices: [Vertex]; let height: Double; let depth: Double }

    static func svg(_ payload: ChatChartPayload) -> String? {
        guard let source = payload.expression, payload.series.isEmpty, payload.data.isEmpty,
              let expression = CurveExpression(source, variables: ["x", "y"]) else { return nil }
        let xMin = payload.xMin ?? -3, xMax = payload.xMax ?? 3
        let yMin = payload.yMin ?? -3, yMax = payload.yMax ?? 3
        guard validRange(xMin, xMax), validRange(yMin, yMax) else { return nil }
        let size = 36
        var samples: [Double?] = []
        for row in 0...size {
            let y = yMin + (yMax-yMin) * Double(row)/Double(size)
            for column in 0...size {
                let x = xMin + (xMax-xMin) * Double(column)/Double(size)
                let z = expression.value(at: x, y: y)
                samples.append(z.isFinite ? z : nil)
            }
        }
        let values = samples.compactMap { $0 }.sorted()
        guard values.count >= 4 else { return nil }
        let robustLow = values[values.count/50], robustHigh = values[values.count-1-values.count/50]
        let outliers = values.last! - values[0] > max(robustHigh-robustLow, 1) * 10
        let low = outliers ? robustLow : values[0], high = outliers ? robustHigh : values.last!
        let padding = high == low ? max(abs(low)*0.1, 1) : (high-low)*0.04
        let zMin = payload.zMin ?? low-padding, zMax = payload.zMax ?? high+padding
        guard validRange(zMin, zMax) else { return nil }
        let heights = samples.map { value -> Double? in
            guard let value, value >= zMin, value <= zMax else { return nil }
            return (value-zMin)/(zMax-zMin)
        }
        func vertex(_ row: Int, _ column: Int) -> Vertex? {
            guard let height = heights[row*(size+1)+column] else { return nil }
            return Vertex(x: Double(column)/Double(size)*2-1, y: Double(row)/Double(size)*2-1, z: (height-0.5)*1.5)
        }
        let yaw = -0.72, pitch = 0.52
        func project(_ vertex: Vertex) -> (x: Double, y: Double, depth: Double) {
            let u = cos(yaw)*vertex.x-sin(yaw)*vertex.y
            let v = sin(yaw)*vertex.x+cos(yaw)*vertex.y
            return (320+u*155, 233+(v*sin(pitch)-vertex.z*cos(pitch))*140, v*cos(pitch)+vertex.z*sin(pitch))
        }
        var faces: [Face] = []
        var triangles: [[Int]] = []
        for row in 0..<size {
            for column in 0..<size {
                guard let a = vertex(row,column), let b = vertex(row,column+1), let c = vertex(row+1,column+1), let d = vertex(row+1,column) else { continue }
                let corners = [a,b,c,d]
                guard corners.map({$0.z}).max()! - corners.map({$0.z}).min()! <= 0.85 else { continue }
                let midX = xMin+(xMax-xMin)*(Double(column)+0.5)/Double(size)
                let midY = yMin+(yMax-yMin)*(Double(row)+0.5)/Double(size)
                let midZ = expression.value(at: midX,y:midY)
                guard midZ.isFinite, midZ >= zMin, midZ <= zMax else { continue }
                for vertices in [[a,b,c],[a,c,d]] {
                    let z = vertices.reduce(0) {$0+$1.z}/3
                    faces.append(Face(vertices:vertices,height:z/1.5+0.5,depth:vertices.reduce(0) {$0+project($1).depth}/3))
                }
                let i = row*(size+1)+column
                triangles.append([i,i+1,i+size+2])
                triangles.append([i,i+size+2,i+size+1])
            }
        }
        guard !faces.isEmpty else { return nil }
        // 把有效三角面索引保存在模型中，交互只投影已有网格，不重新执行表达式。
        let model = Model(size:size,heights:heights,triangles:triangles,ranges:[xMin,xMax,yMin,yMax,zMin,zMax],labels:[payload.xLabel ?? "x",payload.yLabel ?? "y",payload.zLabel ?? "z"],expression:source)
        guard let data = try? JSONEncoder().encode(model) else { return nil }
        var out = ["<figure class=\"mn-chart mn-surface\" contenteditable=\"false\" style=\"margin:14px 0\"><figcaption>\(MathMarkup.escape(payload.title ?? "z = "+source))</figcaption>",
            "<svg class=\"mn-surface-chart\" data-surface=\"\(data.base64EncodedString())\" data-yaw=\"-0.72\" data-pitch=\"0.52\" data-zoom=\"1\" role=\"img\" tabindex=\"0\" aria-label=\"\(MathMarkup.escape("三维曲面 z = "+source+"；拖动或方向键旋转，双击复位"))\" width=\"640\" height=\"490\" viewBox=\"0 0 640 490\" xmlns=\"http://www.w3.org/2000/svg\" style=\"max-width:100%;height:auto;color:inherit;touch-action:none;cursor:grab\">"]
        out.append("<g class=\"mn-surface-faces\">")
        for face in faces.sorted(by: {$0.depth < $1.depth}) {
            let points = face.vertices.map { let p=project($0); return "\(f(p.x)),\(f(p.y))" }.joined(separator:" ")
            let color = "hsl(\(f(230-face.height*190)),65%,55%)"
            out.append("<polygon points=\"\(points)\" fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"0.4\"/>")
        }
        out.append("</g><g class=\"mn-surface-axes\">")
        let origin = Vertex(x:-1,y:-1,z:-0.75)
        let ends = [Vertex(x:1,y:-1,z:-0.75),Vertex(x:-1,y:1,z:-0.75),Vertex(x:-1,y:-1,z:0.75)]
        let o = project(origin)
        for (index,end) in ends.enumerated() {
            let p = project(end)
            out.append("<path d=\"M\(f(o.x)),\(f(o.y)) L\(f(p.x)),\(f(p.y))\" fill=\"none\" stroke=\"currentColor\" stroke-opacity=\"0.7\"/><text x=\"\(f(p.x+6))\" y=\"\(f(p.y-7))\" fill=\"currentColor\" font-size=\"14\">\(MathMarkup.escape(model.labels[index]))</text>")
        }
        out.append("</g><text x=\"320\" y=\"469\" text-anchor=\"middle\" font-size=\"12\" fill=\"currentColor\" opacity=\"0.65\">拖动旋转 · 滚轮缩放 · 双击复位</text></svg></figure>")
        return out.joined()
    }
    private static func validRange(_ min: Double,_ max: Double) -> Bool { min.isFinite && max.isFinite && min < max && (max-min).isFinite }
    private static func f(_ value: Double) -> String { String(format:"%.3f",locale:Locale(identifier:"en_US_POSIX"),value) }
}

extension SurfaceChart {
    static let script = #"""
    (() => {
      'use strict';
      if (window.MiNoteSurface) return;
      const attached = new WeakSet();
      const ns = 'http://www.w3.org/2000/svg';
      const finite = Number.isFinite;
      const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
      function element(name, attributes, content) {
        const node = document.createElementNS(ns, name);
        for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
        if (content !== undefined) node.textContent = content;
        return node;
      }
      function attach(svg) {
        if (attached.has(svg)) return;
        const raw = svg.getAttribute('data-surface');
        if (!raw || raw.length > 300000) return;
        let model;
        try { model = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(raw), c => c.charCodeAt(0)))); } catch (_) { return; }
        if (!Number.isInteger(model.size) || model.size < 2 || model.size > 64 ||
            !Array.isArray(model.heights) || model.heights.length !== (model.size+1)**2 ||
            !model.heights.every(z => z === null || (finite(z) && z >= 0 && z <= 1)) ||
            !Array.isArray(model.triangles) || model.triangles.length > 8192 ||
            !model.triangles.every(t => Array.isArray(t) && t.length === 3 && t.every(i => Number.isInteger(i) && i >= 0 && i < model.heights.length && model.heights[i] !== null)) ||
            !Array.isArray(model.ranges) || model.ranges.length !== 6 || !model.ranges.every(finite) ||
            !Array.isArray(model.labels) || model.labels.length !== 3 || !model.labels.every(x => typeof x === 'string')) return;
        const faces = svg.querySelector('.mn-surface-faces'), axes = svg.querySelector('.mn-surface-axes');
        if (!faces || !axes) return;
        attached.add(svg);
        let yaw = Number(svg.getAttribute('data-yaw')), pitch = Number(svg.getAttribute('data-pitch')), zoom = Number(svg.getAttribute('data-zoom'));
        yaw = finite(yaw) ? yaw : -0.72; pitch = finite(pitch) ? clamp(pitch,-1.35,1.35) : 0.52; zoom = finite(zoom) && zoom > 0 ? clamp(zoom,0.6,1.25) : 1;
        const points = model.heights.map((z, i) => z === null ? null : [i%(model.size+1)/model.size*2-1, Math.floor(i/(model.size+1))/model.size*2-1, (z-0.5)*1.5]);
        function draw() {
          const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
          const project = ([x,y,z]) => { const u = cy*x-sy*y, v = sy*x+cy*y; return [320+u*155*zoom,233+(v*sp-z*cp)*140*zoom,v*cp+z*sp]; };
          const projected = points.map(p => p && project(p));
          const triangles = model.triangles.map(t => ({t, depth:t.reduce((s,i) => s+projected[i][2],0)/3})).sort((a,b) => a.depth-b.depth);
          const fragment = document.createDocumentFragment();
          for (const {t} of triangles) {
            const z = t.reduce((s,i) => s+model.heights[i],0)/3, color = `hsl(${230-z*190},65%,55%)`;
            fragment.append(element('polygon', {points:t.map(i => projected[i].slice(0,2).map(v => v.toFixed(3)).join(',')).join(' '),fill:color,stroke:color,'stroke-width':0.4}));
          }
          faces.replaceChildren(fragment);
          const origin = [-1,-1,-0.75], ends = [[1,-1,-0.75],[-1,1,-0.75],[-1,-1,0.75]], o = project(origin);
          const axisNodes = document.createDocumentFragment();
          ends.forEach((end,index) => {
            const p = project(end);
            axisNodes.append(element('path',{d:`M${o[0]},${o[1]} L${p[0]},${p[1]}`,fill:'none',stroke:'currentColor','stroke-opacity':0.7}));
            axisNodes.append(element('text',{x:p[0]+6,y:p[1]-7,fill:'currentColor','font-size':14},model.labels[index]));
            for (let tick = 0; tick <= 2; tick++) {
              const t = tick/2, position = origin.map((value,i) => value+(end[i]-value)*t), q = project(position);
              const value = model.ranges[index*2]+(model.ranges[index*2+1]-model.ranges[index*2])*t;
              axisNodes.append(element('text',{x:q[0]-4,y:q[1]+13,fill:'currentColor','font-size':10,'text-anchor':'end'},Number(value.toPrecision(3)).toString()));
            }
          });
          axes.replaceChildren(axisNodes);
          svg.setAttribute('data-yaw', String(yaw)); svg.setAttribute('data-pitch', String(pitch)); svg.setAttribute('data-zoom', String(zoom));
        }
        const save = () => svg.dispatchEvent(new Event('input', {bubbles:true}));
        let pointer = null, frame = null;
        const schedule = () => { if (frame === null) frame = requestAnimationFrame(() => {frame=null;draw();}); };
        const flush = () => { if (frame !== null) {cancelAnimationFrame(frame);frame=null;} draw(); };
        svg.addEventListener('pointerdown', event => {
          if (event.button !== 0 || pointer) return;
          event.preventDefault(); svg.focus({preventScroll:true});
          pointer = {id:event.pointerId,x:event.clientX,y:event.clientY};
          try {svg.setPointerCapture(event.pointerId);} catch (_) {}
        });
        svg.addEventListener('pointermove', event => {
          if (!pointer || pointer.id !== event.pointerId) return;
          yaw = (yaw+(event.clientX-pointer.x)*0.012)%(Math.PI*2); pitch=clamp(pitch+(event.clientY-pointer.y)*0.01,-1.35,1.35);
          pointer.x=event.clientX;pointer.y=event.clientY;schedule();
        });
        const end = event => {if (pointer && pointer.id===event.pointerId) {pointer=null;flush();save();}};
        svg.addEventListener('pointerup',end); svg.addEventListener('pointercancel',end); svg.addEventListener('lostpointercapture',end);
        svg.addEventListener('wheel',event => {event.preventDefault();zoom=clamp(zoom*Math.exp(-event.deltaY*0.002),0.6,1.25);flush();save();},{passive:false});
        svg.addEventListener('dblclick',event => {event.preventDefault();yaw=-0.72;pitch=0.52;zoom=1;flush();save();});
        svg.addEventListener('keydown',event => {
          if (!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','+','-','='].includes(event.key)) return;
          event.preventDefault();event.stopPropagation();
          if(event.key==='ArrowLeft')yaw-=0.12; if(event.key==='ArrowRight')yaw+=0.12;
          if(event.key==='ArrowUp')pitch=clamp(pitch-0.12,-1.35,1.35); if(event.key==='ArrowDown')pitch=clamp(pitch+0.12,-1.35,1.35);
          if(event.key==='+'||event.key==='=')zoom=clamp(zoom*1.1,0.6,1.25); if(event.key==='-')zoom=clamp(zoom/1.1,0.6,1.25);
          if(event.key==='Home'){yaw=-0.72;pitch=0.52;zoom=1;} flush();save();
        });
        draw();
      }
      window.MiNoteSurface = {start(root=document.body) {
        const nodes = (root.matches && root.matches('svg[data-surface]') ? [root] : []).concat(Array.from(root.querySelectorAll('svg[data-surface]')));
        for (const node of nodes) attach(node);
      }};
    })();
    """#
}
