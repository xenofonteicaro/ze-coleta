import Foundation
import SwiftUI

let releaseVersion = Bundle.main.object(forInfoDictionaryKey: "ZeColetaReleaseVersion") as? String ?? "0.1.0-alpha.1"

switch CommandLine.arguments.dropFirst().first {
case "--version":
    print("Zé Coleta \(releaseVersion)")
case "--help", "-h":
    print("""
    Zé Coleta \(releaseVersion)
    Utilitário macOS local e open source.

    ze-coleta             Abre o aplicativo
    ze-coleta --version   Mostra a versão
    ze-coleta --help      Mostra esta ajuda

    A análise e a seleção de arquivos são feitas na interface do aplicativo.
    """)
case nil:
    ZeColetaApp.main()
default:
    FileHandle.standardError.write(Data("Argumento desconhecido. Use ze-coleta --help.\n".utf8))
    exit(64)
}
