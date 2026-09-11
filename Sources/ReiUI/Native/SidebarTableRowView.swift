import AppKit

/// Keeps native sidebar selection neutral when focus moves into the content pane.
final class SidebarTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = false }
    }
}
