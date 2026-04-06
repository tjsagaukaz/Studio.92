import SwiftUI

struct WorkspaceBackground: View {
    var body: some View {
        StudioSurface.base
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
