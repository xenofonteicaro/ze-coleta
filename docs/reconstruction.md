# Investigação que orientou o Zé Coleta

O Zé Coleta é uma implementação independente. Nenhum binário, arte, texto de
interface ou base de regras do CleanMyMac é incorporado ao projeto.

## Alvo e método

Em 15 de outubro de 2026 foi inspecionado o pacote instalado
`/Applications/CleanMyMac_5_MAS.app`, bundle ID
`com.macpaw.CleanMyMac-mas`, versão 5.7.1, build 50701.0.2609301754.
O executável universal tem SHA-256
`e7861e5dcdbf0c03ae367cf91e4176f26ba187fdb16bd0035fe5e4ee6b301f01`.

Foi usado REA CLI 6.5.0 para inventário, estrutura Mach-O, plist e assinatura.
`nm` e `swift-demangle` complementaram a inspeção dos símbolos públicos de
seis frameworks. `plutil` interpretou recursos de localização no formato
original. Os registros completos de Evidence ficaram retidos localmente.

| Observação | Evidence do REA |
| --- | --- |
| Identidade e versão do plist | `ev_52b9c6b38f8fcaa7d5628c3012ce58ed53842a7a4060ed81879e4833f3b02bf1` |
| Mach-O Intel/Apple Silicon; mínimo declarado macOS 11 | `ev_04cc80596c2b75f8350c24bd4fd57e3cc706276092abdcda95d40d6014e05a8b` |
| Assinatura declarada e entitlements | `ev_d7e5973f7f3723e2b227b52a516071a7d415aba9c351eb6ecafde0021cf63ea1` |
| Inventário estático do pacote | `ev_1d6ece09af9e54ef087c65ff2178234cfcbfbe94f2690cec041ced82e136c96c` |

O inventário possui 3.183 nós e 4.995 ocorrências, com 132 frameworks de
primeiro nível observados por inventário de diretório. A assinatura declara
App Sandbox e permissões de arquivos escolhidos pelo usuário. A inspeção da
assinatura não estabelece validade de confiança em tempo de execução.

## Estrutura observada e inferências

| Evidência estática observada | Inferência limitada |
| --- | --- |
| `SystemJunkScanTasksFactory` expõe tarefas de caches, logs e DerivedData | Há scanners especializados e parametrizados por bases de conhecimento; os critérios internos não foram recuperados. |
| `OrganizeScanning.BatchBasedScanner` expõe callbacks de lotes, pausa, retomada e cancelamento | A interface pública prevê enumeração controlável por lotes; não estabelece os limites efetivos nem o desempenho. |
| `UninstallerApplicationCore` expõe coleção de recursos e conclusão de scan; factories expõem tarefas de apps e sobras | A modelagem distingue aplicativo e recursos relacionados; regras exatas de atribuição permanecem desconhecidas. |
| `CleaningCore.FileRemover.remove(at:)` e `TasksProcessor` com cancelamento | Existe uma camada de remoção separada da varredura. O nome `remove` não prova que o original use Lixeira ou exclusão permanente. |
| `FileRemoval.ProtectedFolderSet` e erros de pasta protegida | Existe uma política explícita de pastas protegidas; sua lista e semântica completas não foram recuperadas. |
| Recursos descrevem revisão, arquivos grandes e efeitos em conteúdo na nuvem | São intenções de interface presentes no pacote, não execução observada. |

A edição App Store tem diferenças de disponibilidade documentadas pela
[MacPaw](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features).
A presença de um framework ou de uma string não estabelece que seu recurso
esteja habilitado nessa edição.

## Decisões próprias do Zé Coleta

O usuário escolheu limpeza, arquivos grandes e desinstalação como primeiro
escopo. O app usa APIs públicas de macOS, regras próprias e dados locais.
O envio à Lixeira usa a API
[`FileManager.trashItem`](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)).
Ele não promete reproduzir os algoritmos ou a cobertura do CleanMyMac.

Não há antivírus, limpeza de nuvem, atualização de outros aplicativos,
esvaziamento automático da Lixeira, remoção de snapshots, root helper ou
limpeza de RAM nesta versão. Esses são limites da implementação inicial,
não alegações sobre o aplicativo investigado.

## Limitações da investigação

Não havia Hopper, Ghidra ou IDA configurado. Não foi realizada decompilação
de corpos de função nem reconstrução completa dos fluxos internos.
Na interface foram observados inicialmente o aviso de termos e, em uma
atualização posterior, a tela principal e as introduções dos módulos
Aplicativos e Limpeza. A introdução de Limpeza enumerou lixo do sistema,
arquivos de IA, anexos de e-mail e lixeiras. O agente não realizou aceite de
termos nem executou varredura ou limpeza no original. Assim, não há comparação comportamental de scans,
remoções, falsos positivos, desempenho ou serviços remotos.

Os resultados são suficientes para orientar uma alternativa independente
com escopo reduzido. Eles não constituem engenharia reversa exaustiva nem
prova de equivalência funcional.
