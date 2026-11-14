import SwiftUI

/// Settings → Diagnostics: the development log, shareable straight from the phone.
struct DiagnosticsView: View {
    @State private var text = "Loading…"
    @State private var fileURL: URL?
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("diagnostics.text")
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                Spacer()
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("diagnostics.share")
                }
                Spacer()
                Button("Clear", role: .destructive) {
                    Diag.clear()
                    reload()
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        copied = false
        Diag.text { text = $0 }
        Diag.exportFile { fileURL = $0 }
    }
}
