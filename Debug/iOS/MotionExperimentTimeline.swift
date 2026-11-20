#if DEBUG && os(iOS)
import SwiftUI

@available(iOS 16.2, *)
struct MotionExperimentTimeline: View {
    let session: MotionExperimentSession
    let axes: MotionAxes
    let edits: MotionExperimentEdits
    let thumbnails: [Int: UIImage]
    let vertical: Bool
    let zoom: Double
    let position: Double
    let playing: Bool
    @Binding var selection: MotionTimeRange?
    let seek: (Double) -> Void
    private var duration: Double { max(0.1, session.duration) }

    var body: some View {
        GeometryReader { geometry in
            let length = max(vertical ? geometry.size.height : geometry.size.width, duration * zoom)
            let cross = vertical ? max(geometry.size.width, 280 + Double(edits.tags.count) * 24) : max(geometry.size.height, 270 + Double(edits.tags.count) * 24)
            ScrollViewReader { reader in
                ScrollView(vertical ? [.vertical, .horizontal] : [.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Group {
                            if vertical {
                                LazyVStack(spacing: 0) {
                                    ForEach(0..<Int(ceil(length / 1000)), id: \.self) { tile in
                                        canvasTile(tile, length: length, cross: cross)
                                    }
                                }
                            } else {
                                LazyHStack(spacing: 0) {
                                    ForEach(0..<Int(ceil(length / 1000)), id: \.self) { tile in
                                        canvasTile(tile, length: length, cross: cross)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            seek(min(duration, max(0, (vertical ? value.location.y : value.location.x) / length * duration)))
                        })
                        if let selection {
                            handle(at: selection.start, start: true, length: length, cross: cross)
                            handle(at: selection.end, start: false, length: length, cross: cross)
                        }
                    }
                    .frame(width: vertical ? cross : length, height: vertical ? length : cross)
                    .coordinateSpace(name: "motionTimeline")
                    .id("motionTimelineContent")
                }
                .onChange(of: vertical) { _ in follow(reader, length: length, viewport: vertical ? geometry.size.height : geometry.size.width) }
                .onChange(of: zoom) { _ in follow(reader, length: length, viewport: vertical ? geometry.size.height : geometry.size.width) }
                .onChange(of: playing) { if $0 { follow(reader, length: length, viewport: vertical ? geometry.size.height : geometry.size.width) } }
                .onChange(of: position) { _ in
                    if playing { follow(reader, length: length, viewport: vertical ? geometry.size.height : geometry.size.width) }
                }

            }
        }
        .background(Color.secondary.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video, X Y Z acceleration and tag timeline")
    }
    private func follow(_ reader: ScrollViewProxy, length: Double, viewport: Double) {
        // ScrollViewReader aligns the same normalized point of content and
        // viewport. Solve for the offset that keeps the playhead at the center.
        // Target real layout bounds (not offset-only one-second markers).
        let travel = max(0, length - viewport)
        let offset = min(travel, max(0, position / duration * length - viewport / 2))
        let fraction = travel > 0 ? offset / travel : 0
        let anchor = vertical ? UnitPoint(x: 0, y: fraction) : UnitPoint(x: fraction, y: 0)
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { reader.scrollTo("motionTimelineContent", anchor: anchor) }
        }
    }
    private func canvasTile(_ tile: Int, length: Double, cross: Double) -> some View {
        let origin = Double(tile) * 1000
        let extent = min(1000, length - origin)
        return Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.translateBy(x: vertical ? 0 : -origin, y: vertical ? -origin : 0)
            draw(context: &context, length: length, cross: cross, tileStart: origin / length * duration, tileEnd: (origin + extent) / length * duration)
        }.frame(width: vertical ? cross : extent, height: vertical ? extent : cross)
    }
    private func handle(at second: Double, start: Bool, length: Double, cross: Double) -> some View {
        let location = second / duration * length
        return Image(systemName: vertical ? "line.3.horizontal" : "line.3.horizontal.decrease")
            .font(.caption.bold()).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.blue, in: RoundedRectangle(cornerRadius: 8))
            .offset(x: vertical ? 0 : min(length - 44, max(0, location - 22)),
                    y: vertical ? min(length - 44, max(0, location - 22)) : 0)
            .gesture(DragGesture(coordinateSpace: .named("motionTimeline")).onChanged { value in
                guard var range = selection else { return }
                let location = vertical ? value.location.y : value.location.x
                let next = min(duration, max(0, location / length * duration))
                if start { range.start = min(range.end, next) } else { range.end = max(range.start, next) }
                selection = range
            })
            .accessibilityLabel(start ? "Selection start" : "Selection end")
            .accessibilityValue(String(format: "%.2f seconds", second))
            .accessibilityAdjustableAction { direction in
                guard var range = selection else { return }
                let value = min(duration, max(0, second + (direction == .increment ? 0.1 : -0.1)))
                if start { range.start = min(range.end, value) } else { range.end = max(range.start, value) }
                selection = range
            }
    }
    private func draw(context: inout GraphicsContext, length: Double, cross: Double, tileStart: Double, tileEnd: Double) {
        func rect(_ start: Double, _ end: Double, _ lane: Double, _ width: Double) -> CGRect {
            let a = start / duration * length, b = end / duration * length
            return vertical ? CGRect(x: lane, y: a, width: width, height: max(1, b - a)) : CGRect(x: a, y: lane, width: max(1, b - a), height: width)
        }
        context.fill(Path(rect(0, edits.trim.start, 0, cross)), with: .color(.gray.opacity(0.22)))
        context.fill(Path(rect(edits.trim.end, duration, 0, cross)), with: .color(.gray.opacity(0.22)))
        let tick = zoom < 10 ? 10 : 5
        for second in stride(from: 0, through: Int(duration), by: tick) {
            let point = Double(second) / duration * length
            var path = Path()
            path.move(to: vertical ? CGPoint(x: 0, y: point) : CGPoint(x: point, y: 0))
            path.addLine(to: vertical ? CGPoint(x: cross, y: point) : CGPoint(x: point, y: cross))
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            context.draw(Text("\(second)s").font(.system(size: 10)).foregroundColor(.secondary),
                         at: vertical ? CGPoint(x: 16, y: point + 8) : CGPoint(x: point + 12, y: 12))
        }
        for (second, image) in thumbnails {
            let area = rect(Double(second), min(duration, Double(second + 5)), 28, 54)
            let scale = min(area.width / image.size.width, area.height / image.size.height)
            let imageRect = CGRect(x: area.midX - image.size.width * scale / 2, y: area.midY - image.size.height * scale / 2,
                                   width: image.size.width * scale, height: image.size.height * scale)
            context.fill(Path(area), with: .color(.black.opacity(0.12)))
            context.draw(Image(uiImage: image), in: imageRect)
        }
        let colors: [Color] = [.red, .green, .blue]
        for axis in 0..<3 {
            let lane = 92 + Double(axis) * 54
            let center = lane + 24
            // A zero line is a scale guide, not a fabricated sensor measurement.
            context.fill(Path(rect(tileStart, tileEnd, center, 0.5)), with: .color(.secondary.opacity(0.3)))
            for run in axes.runs {
                var line = Path()
                var began = false
                var count = 0
                var last = CGPoint.zero
                for point in run.points where point.second >= tileStart - 0.1 && point.second <= tileEnd + 0.1 {
                    let t = point.second / duration * length
                    let value = center + (vertical ? 1 : -1) * point.values[axis] / axes.limit * 22
                    let location = vertical ? CGPoint(x: value, y: t) : CGPoint(x: t, y: value)
                    if began { line.addLine(to: location) } else { line.move(to: location); began = true }
                    last = location; count += 1
                }
                if count == 1 { context.fill(Path(ellipseIn: CGRect(x: last.x - 1, y: last.y - 1, width: 2, height: 2)), with: .color(colors[axis])) }
                context.stroke(line, with: .color(colors[axis]), lineWidth: 1.2)
            }
            context.draw(Text(["X", "Y", "Z"][axis]).font(.system(size: 10, weight: .bold)).foregroundColor(colors[axis]),
                         at: vertical ? CGPoint(x: center, y: tileStart / duration * length + 10) : CGPoint(x: tileStart / duration * length + 10, y: lane + 7))
        }
        for (index, tag) in edits.tags.enumerated() {
            let lane = 265 + Double(index) * 24
            for interval in edits.intervals where interval.tagID == tag.id {
                let area = rect(interval.range.start, interval.range.end, lane, 20)
                context.fill(Path(roundedRect: area, cornerRadius: 3), with: .color(motionTagColor(tag.color).opacity(0.65)))
                if !vertical && area.width > 25 {
                    context.draw(Text(tag.name).font(.system(size: 10)).foregroundColor(.white), at: CGPoint(x: area.midX, y: area.midY))
                }
            }
            if vertical {
                context.draw(Text(String(tag.name.prefix(3))).font(.system(size: 9)).foregroundColor(.primary), at: CGPoint(x: lane + 10, y: 12))
            }
        }
        if let selection {
            let area = rect(selection.start, selection.end, 0, cross)
            context.fill(Path(area), with: .color(.blue.opacity(0.08)))
            context.stroke(Path(area), with: .color(.blue), lineWidth: 2)
        }
        context.fill(Path(rect(position, position, 0, cross)), with: .color(.red))
    }
}
#endif
