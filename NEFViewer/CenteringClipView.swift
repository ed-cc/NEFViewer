import AppKit

class CenteringClipView: NSClipView {

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {

        guard let documentView = documentView else {
            return super.constrainBoundsRect(proposedBounds)
        }

        var bounds = super.constrainBoundsRect(proposedBounds)
        let docFrame = documentView.frame

        if docFrame.width < bounds.width {
            bounds.origin.x = -(bounds.width - docFrame.width) / 2
        }

        if docFrame.height < bounds.height {
            bounds.origin.y = -(bounds.height - docFrame.height) / 2
        }

        return bounds
    }
}
