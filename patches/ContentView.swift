import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject var llamaState = LlamaState()
    @State private var multiLineText = ""
    @State private var showingHelp = false    // To track if Help Sheet should be shown
    @State private var selectedImageItem: PhotosPickerItem? = nil
    @State private var pendingImagePath: String? = nil
    @State private var pendingImageThumb: UIImage? = nil

    var body: some View {
        NavigationView {
            VStack {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(llamaState.messageLog)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                }

                TextEditor(text: $multiLineText)
                    .frame(height: 80)
                    .padding()
                    .border(Color.gray, width: 0.5)

                if let thumb = pendingImageThumb {
                    HStack {
                        Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 80).cornerRadius(6)
                        Button("Remove image") { pendingImagePath = nil; pendingImageThumb = nil; selectedImageItem = nil }.foregroundColor(.red)
                        Spacer()
                    }.padding(.horizontal)
                }

                HStack {
                    PhotosPicker(selection: $selectedImageItem, matching: .images) {
                        Image(systemName: "photo")
                    }
                    .onChange(of: selectedImageItem) { _ in handlePickedImage() }

                    Button("Send") {
                        sendText()
                    }

                    Button("Bench") {
                        bench()
                    }

                    Button("Clear") {
                        clear()
                    }

                    Button("Copy") {
                        UIPasteboard.general.string = llamaState.messageLog
                    }
                }
                .buttonStyle(.bordered)
                .padding()

                NavigationLink(destination: DrawerView(llamaState: llamaState)) {
                    Text("View Models")
                }
                .padding()

            }
            .padding()
            .navigationBarTitle("Model Settings", displayMode: .inline)

        }
    }

    func sendText() {
        let prompt = multiLineText
        let imagePath = pendingImagePath
        Task {
            await llamaState.complete(text: prompt, imagePath: imagePath)
            await MainActor.run {
                multiLineText = ""
                pendingImagePath = nil
                pendingImageThumb = nil
                selectedImageItem = nil
            }
        }
    }

    func handlePickedImage() {
        guard let item = selectedImageItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data),
               let jpeg = img.jpegData(compressionQuality: 0.92) {
                let dir = FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("input-\(UUID().uuidString).jpg")
                try? jpeg.write(to: url)
                await MainActor.run {
                    pendingImagePath = url.path
                    pendingImageThumb = img
                }
            }
        }
    }

    func bench() {
        Task {
            await llamaState.bench()
        }
    }

    func clear() {
        Task {
            await llamaState.clear()
        }
    }
    struct DrawerView: View {

        @ObservedObject var llamaState: LlamaState
        @State private var showingHelp = false
        func delete(at offsets: IndexSet) {
            offsets.forEach { offset in
                let model = llamaState.downloadedModels[offset]
                let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    print("Error deleting file: \(error)")
                }
            }

            // Remove models from downloadedModels array
            llamaState.downloadedModels.remove(atOffsets: offsets)
        }

        func getDocumentsDirectory() -> URL {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0]
        }
        var body: some View {
            List {
                Section(header: Text("Download Models From Hugging Face")) {
                    HStack {
                        InputButton(llamaState: llamaState)
                    }
                }
                Section(header: Text("Downloaded Models")) {
                    ForEach(llamaState.downloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                    .onDelete(perform: delete)
                }
                Section(header: Text("Default Models")) {
                    ForEach(llamaState.undownloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                }

            }
            .listStyle(GroupedListStyle())
            .navigationBarTitle("Model Settings", displayMode: .inline).toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Help") {
                        showingHelp = true
                    }
                }
            }.sheet(isPresented: $showingHelp) {    // Sheet for help modal
                NavigationView {
                    VStack(alignment: .leading) {
                        VStack(alignment: .leading) {
                            Text("1. Make sure the model is in GGUF Format")
                                    .padding()
                            Text("2. Copy the download link of the quantized model")
                                    .padding()
                        }
                        Spacer()
                    }
                    .navigationTitle("Help")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingHelp = false
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
