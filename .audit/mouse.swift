// Audit input/window helper: mouse move|click|rclick x y · win · list · union
// mouse move|click|rclick x y   ·   mouse win  (prints ESPDock main window id x y w h)
import CoreGraphics
import Foundation
let a = CommandLine.arguments
func post(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)?.post(tap: .cghidEventTap)
}
if a[1] == "win" {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l where (w[kCGWindowOwnerName as String] as? String) == "ESPDock" && (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        print(w[kCGWindowNumber as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)); break
    }
    exit(0)
}
if a[1] == "list" {  // every on-screen ESPDock window, back to front: id x y w h
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l.reversed() where (w[kCGWindowOwnerName as String] as? String) == "ESPDock" {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        if b["Width"]! < 40 || b["Height"]! < 40 { continue }
        print(w[kCGWindowNumber as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
    }
    exit(0)
}
if a[1] == "union" {  // union of all on-screen ESPDock windows (main + menus/popovers): x y w h
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    var r = CGRect.null
    for w in l where (w[kCGWindowOwnerName as String] as? String) == "ESPDock" {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        if b["Width"]! < 40 || b["Height"]! < 40 { continue }
        r = r.union(CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
    }
    print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)); exit(0)
}
let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
switch a[1] {
case "move": post(.mouseMoved, p)
case "click": post(.mouseMoved, p); usleep(80_000); post(.leftMouseDown, p); usleep(60_000); post(.leftMouseUp, p)
case "rclick": post(.mouseMoved, p); usleep(80_000); post(.rightMouseDown, p, .right); usleep(60_000); post(.rightMouseUp, p, .right)
default: break
}
