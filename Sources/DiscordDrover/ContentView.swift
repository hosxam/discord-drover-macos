import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: DroverController
    @State private var choosingPacket = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Discord Drover")
                .font(.title.bold())
            Text("Launch Discord through a local proxy or apply Direct mode voice-traffic handling.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Discord application", selection: $controller.selectedApplicationPath) {
                    if controller.applications.isEmpty {
                        Text("No installed Discord app found").tag("")
                    }
                    ForEach(controller.applications) { application in
                        Text(application.name).tag(application.path)
                    }
                }

                Picker("Mode", selection: $controller.mode) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if controller.mode != .direct {
                    TextField("Proxy host", text: $controller.host)
                    TextField("Proxy port", text: $controller.port)

                    if controller.mode == .http {
                        Toggle("Proxy authentication", isOn: $controller.authentication)
                        if controller.authentication {
                            TextField("Login", text: $controller.login)
                            SecureField("Password", text: $controller.password)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: controller.mode == .direct ? 160 : controller.authentication ? 290 : 235)

            HStack {
                Text("Optional UDP packet:")
                Text(controller.hasPacket ? "Installed" : "Not installed")
                    .foregroundStyle(controller.hasPacket ? .green : .secondary)
                Spacer()
                Button("Import...") {
                    choosingPacket = true
                }
                if controller.hasPacket {
                    Button("Remove") {
                        controller.removePacket()
                    }
                }
            }

            if !controller.status.isEmpty {
                Text(controller.status)
                    .foregroundStyle(controller.statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Remove Managed Copy") {
                    controller.removeManagedCopy()
                }
                .disabled(controller.busy)

                if controller.canRevealManagedCopy {
                    Button("Reveal Prepared Discord") {
                        controller.revealManagedCopy()
                    }
                    .disabled(controller.busy)
                }

                Spacer()

                Button("Refresh Apps") {
                    controller.refreshApplications()
                }
                .disabled(controller.busy)

                Button("Prepare and Launch Discord") {
                    controller.prepareAndLaunch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.busy || controller.selectedApplicationPath.isEmpty)
            }
        }
        .padding(22)
        .fileImporter(
            isPresented: $choosingPacket,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            controller.importPacket(result)
        }
    }
}
