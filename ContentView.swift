import SwiftUI
import CoreImage

struct ContentView: View {
    @State private var inputText = "Hello, World!"
    @State private var errorLevel: QRErrorLevel = .M
    @State private var qrImage: Image?
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // QR Code Display
                if let qrImage = qrImage {
                    qrImage
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 200, height: 200)
                }
                
                // Input Text Field
                TextField("Enter text for QR code", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                
                // Error Level Picker
                Picker("Error Correction Level", selection: $errorLevel) {
                    Text("Low (7%)").tag(QRErrorLevel.L)
                    Text("Medium (15%)").tag(QRErrorLevel.M)
                    Text("Quarter (25%)").tag(QRErrorLevel.Q)
                    Text("High (30%)").tag(QRErrorLevel.H)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                
                // Generate Button
                Button(action: generateQRCode) {
                    Text("Generate QR Code")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(10)
                }
            }
            .padding()
            .navigationTitle("QR Code Generator")
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func generateQRCode() {
        guard !inputText.isEmpty else {
            showError(message: "Please enter some text")
            return
        }
        
        do {
            let qrCode = try QRCodeGenerator.generate(
                from: inputText,
                errorLevel: errorLevel
            )
            
            if let cgImage = qrCode.toImage(moduleSize: 10) {
                qrImage = Image(cgImage, scale: 1.0, label: Text("QR Code"))
            } else {
                showError(message: "Failed to create QR code image")
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }
    
    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

#Preview {
    ContentView()
}
