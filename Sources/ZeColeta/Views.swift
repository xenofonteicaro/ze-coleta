import ColetaCore
import SwiftUI

enum Palette {
    static let background = Color(red: 0.965, green: 0.970, blue: 0.951)
    static let sidebar = Color(red: 0.929, green: 0.945, blue: 0.914)
    static let ink = Color(red: 0.094, green: 0.227, blue: 0.204)
    static let green = Color(red: 0.078, green: 0.478, blue: 0.384)
    static let muted = Color(red: 0.410, green: 0.475, blue: 0.447)
    static let line = Color(red: 0.875, green: 0.902, blue: 0.867)
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Text("ZC").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 38).background(Palette.green, in: RoundedRectangle(cornerRadius: 12))
                    Text("Zé Coleta").font(.system(size: 23, weight: .semibold, design: .rounded))
                }.padding(.top, 18)
                Text("Seu Mac. Tudo no lugar.").font(.caption).foregroundStyle(Palette.muted).padding(.top, -18)
                VStack(spacing: 7) {
                    ForEach(Destination.allCases) { destination in
                        Button { model.destination = destination } label: {
                            Label(destination.title, systemImage: destination.icon)
                                .font(.system(size: 13, weight: model.destination == destination ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .foregroundStyle(model.destination == destination ? Palette.green : Palette.muted)
                                .background(model.destination == destination ? Palette.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label("Funciona no seu Mac", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(Palette.green)
                    Text("Código aberto · sem assinatura").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Link("Código-fonte ↗", destination: URL(string: "https://github.com/xenofonteicaro/ze-coleta")!).font(.system(size: 10))
                }
            }.padding(20).background(Palette.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 245)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Seu Mac, com mais espaço.").font(.caption).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(model.isScanning ? "\(model.examinedEntries.formatted()) entradas examinadas" : "Processamento local").font(.caption2).foregroundStyle(Palette.muted)
                    }
                    if model.destination == .overview { OverviewView(model: model) }
                    else { ResultsView(model: model) }
                    StatusView(model: model)
                    Divider().overlay(Palette.line)
                    HStack {
                        Text("Escolha explícita · Lixeira do macOS").font(.system(size: 10))
                        Spacer()
                        Text("Zé Coleta 0.1").font(.system(size: 10))
                    }.foregroundStyle(Palette.muted)
                }.padding(34)
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $model.isReviewPresented) { ReviewView(model: model) }
        .alert("Zé Coleta", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 25) {
            VStack(alignment: .leading, spacing: 15) {
                Eyebrow(text: "SIMPLES. LOCAL. SEU.")
                Text("Deixe espaço\npara o que importa.").font(.system(size: 35, weight: .semibold)).tracking(-1)
                Text("Encontre o que está ocupando o Mac.\nEscolha o que sai. Você tem o controle.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
                ScanButton(model: model).padding(.top, 8)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let disk = model.disk {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Palette.green.opacity(0.12), lineWidth: 14)
                        Circle().trim(from: 0, to: disk.total > 0 ? min(1, max(0, Double(disk.total - disk.available) / Double(disk.total))) : 0)
                            .stroke(Palette.green, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 5) {
                            Text(byteLabel(disk.available)).font(.system(size: 26, weight: .medium))
                            Text("disponíveis para uso").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }.frame(width: 156, height: 156)
                    Text("Volume de \(byteLabel(disk.total))").font(.caption2).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 10)
            }
        }.padding(.vertical, 15)
        HStack {
            Text("Encontre seu próximo respiro").font(.system(size: 16, weight: .semibold))
            Spacer()
            Text(model.report == nil ? "Comece com uma análise" : "Resultados para revisão").font(.caption2).foregroundStyle(Palette.muted)
        }
        HStack(alignment: .top, spacing: 12) {
            ForEach([Destination.cleanup, .large, .applications]) { destination in
                SummaryCard(destination: destination, items: model.items(for: destination), hasReport: model.hasReport(for: destination)) {
                    model.destination = destination
                }
            }
        }
        InfoCard(title: "Uma análise não apaga nada.", detail: "Você revisa os caminhos e confirma cada ação. Os itens aprovados vão para a Lixeira do macOS.")
    }
}

struct SummaryCard: View {
    let destination: Destination
    let items: [ScanItem]
    let hasReport: Bool
    let action: () -> Void

    var detail: String {
        switch destination {
        case .cleanup: "Caches, registros e dados gerados pelo Xcode."
        case .large: "Arquivos grandes nas pastas escolhidas por você."
        default: "Apps e arquivos relacionados para revisar."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: destination.icon).font(.system(size: 19)).foregroundStyle(Palette.green)
                .frame(width: 35, height: 35).background(Palette.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            Text(destination.title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(height: 34, alignment: .top)
            Spacer(minLength: 0)
            HStack {
                Text(hasReport ? (destination == .applications ? "\(items.count) apps" : byteLabel(items.reduce(0) { $0 + $1.bytes })) : "—")
                    .font(.system(size: 20, weight: .medium))
                Spacer()
                Button("Revisar →", action: action).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.green)
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
    }
}

struct ResultsView: View {
    @ObservedObject var model: AppModel

    var title: String {
        switch model.destination {
        case .cleanup: "Só o que você escolher."
        case .large: "Veja onde está o espaço."
        default: "Desinstale com clareza."
        }
    }
    var subtitle: String {
        switch model.destination {
        case .cleanup: "Revise os arquivos temporários encontrados. Caches são recriados; remover builds pode tornar a próxima compilação mais lenta."
        case .large: "Tamanho ajuda a encontrar. A decisão de remover continua sendo sua."
        default: "Revise o aplicativo e escolha seus arquivos relacionados separadamente. Dados e grupos compartilhados ficam preservados."
        }
    }

    var body: some View {
        let visibleItems = model.visibleItems
        let orphanRelatedItems = model.destination == .applications ? model.orphanRelatedItems : []
        VStack(alignment: .leading, spacing: 13) {
            Eyebrow(text: model.destination.title.uppercased())
            Text(title).font(.system(size: 31, weight: .semibold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(3)
        }
        if model.destination == .large {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Button("Escolher pastas…", systemImage: "folder") { model.chooseFolders() }.disabled(model.isBusy)
                    Spacer()
                    Picker("Tamanho mínimo", selection: $model.minimumSize) {
                        Text("100 MB").tag(Int64(100_000_000))
                        Text("500 MB").tag(Int64(500_000_000))
                        Text("1 GB").tag(Int64(1_000_000_000))
                    }.fixedSize().disabled(model.isBusy)
                }
                ForEach(model.largeRoots, id: \.self) { url in
                    Text(url.path(percentEncoded: false)).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
            }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 10))
        }
        HStack {
            ScanButton(model: model)
            Spacer()
            Text("Nada selecionado automaticamente").font(.caption2).foregroundStyle(Palette.muted)
        }
        if visibleItems.isEmpty && orphanRelatedItems.isEmpty {
            ContentUnavailableView(!model.hasReport(for: model.destination) ? "Comece com uma análise" : "Nenhum candidato nesta seleção",
                                   systemImage: model.destination.icon,
                                   description: Text(!model.hasReport(for: model.destination) ? "A análise só lê os locais definidos para esta seção." : "Consulte a cobertura abaixo antes de concluir que uma pasta está vazia."))
                .frame(minHeight: 170)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        ItemRow(item: item, isSelected: model.selection(item), reveal: { model.reveal(item) })
                        if item.category == .applications {
                            let related = model.related(to: item)
                            if !related.isEmpty {
                                DisclosureGroup("\(related.count) arquivo(s) relacionado(s) — seleção separada") {
                                    VStack(spacing: 12) {
                                        ForEach(related) { resource in
                                            ItemRow(item: resource, isSelected: model.selection(resource), reveal: { model.reveal(resource) })
                                        }
                                    }.padding(.top, 10)
                                }.font(.caption).foregroundStyle(Palette.muted).padding(.leading, 29)
                            }
                        }
                    }.padding(15)
                    if item.id != visibleItems.last?.id { Divider().overlay(Palette.line) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                .disabled(model.isBusy)
            if !orphanRelatedItems.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Arquivos relacionados de outros apps").font(.system(size: 13, weight: .semibold))
                    Text("O aplicativo proprietário não está entre os candidatos desta lista. Estes arquivos continuam disponíveis para revisão separada.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    ForEach(orphanRelatedItems) { item in
                        ItemRow(item: item, isSelected: model.selection(item), reveal: { model.reveal(item) })
                        Divider()
                    }
                }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                    .disabled(model.isBusy)
            }
        }
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(model.selectedItems.count) selecionado(s) · \(byteLabel(model.selectedBytes))")
                    .font(.system(size: 12, weight: .medium))
                Text("A seleção pode incluir itens de outras seções.").font(.caption2).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("Revisar seleção →") { model.reviewSelection() }
                .buttonStyle(.borderedProminent).disabled(model.selectedItems.isEmpty || model.isBusy)
        }
    }
}

struct ItemRow: View {
    let item: ScanItem
    @Binding var isSelected: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Selecionar \(item.name)", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel("Selecionar \(item.name)")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                Text(item.url.path(percentEncoded: false)).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                Text(item.detail).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                if let owner = item.ownerAppURL {
                    Text("Relacionado a \(owner.path(percentEncoded: false))").font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(byteLabel(item.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            Button(action: reveal) { Image(systemName: "folder") }.buttonStyle(.plain).foregroundStyle(Palette.green)
                .help("Mostrar no Finder").accessibilityLabel("Mostrar \(item.name) no Finder")
        }
    }
}

struct ScanButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Button("Cancelar análise") { model.cancelScan() }
            } else {
                Button(model.report == nil ? "Analisar" : "Analisar novamente") { model.startScan() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
            }
        }
    }
}

struct StatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.status).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                .accessibilityAddTraits(.updatesFrequently)
            if let date = model.reportDate {
                Text("Resultados da análise de \(date.formatted(date: .abbreviated, time: .standard)). A identidade dos itens é verificada novamente antes de mover.")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            if let report = model.report, !report.issues.isEmpty {
                DisclosureGroup("Cobertura da análise · \(report.issues.count) observação(ões)") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption2).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }.font(.caption).foregroundStyle(Palette.muted)
            }
            if !model.outcomes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Resultado por item").font(.caption.bold())
                    ForEach(Array(model.outcomes.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(result.item.name, systemImage: result.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                            Text(result.error ?? "Movido para: \(result.destination?.path(percentEncoded: false) ?? "Lixeira")")
                                .font(.caption2).textSelection(.enabled)
                        }.foregroundStyle(result.error == nil ? Palette.green : .orange)
                    }
                    Text("Mover para a Lixeira não libera espaço imediatamente. Os itens continuam recuperáveis pelo Finder.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "REVISÃO DA SELEÇÃO")
            Text("Confira antes de continuar.").font(.system(size: 25, weight: .semibold))
            Text("\(model.selectedItems.count) item(ns) · \(byteLabel(model.selectedBytes)) estimados. A ação move os itens à Lixeira, onde podem ser recuperados pelo Finder.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.selectedItems) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).font(.system(size: 12, weight: .semibold))
                            Text(item.url.path(percentEncoded: false)).font(.caption2).foregroundStyle(Palette.muted).textSelection(.enabled)
                            Text(item.detail).font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 300)
            Text("Arquivos de apps em uso não podem ser removidos. Caches e builds podem precisar ser recriados.")
                .font(.caption2).foregroundStyle(Palette.muted)
            HStack {
                Button("Voltar", role: .cancel) { model.isReviewPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Mover para a Lixeira", role: .destructive) { model.moveSelectionToTrash() }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
        }.padding(28).frame(width: 580).background(Palette.background)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(Palette.green)
    }
}

struct InfoCard: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield").font(.system(size: 19)).foregroundStyle(Palette.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
        }.padding(17).background(Palette.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}
