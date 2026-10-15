# Zé Coleta — desenho aprovado

O usuário aprovou em 15 de outubro de 2026 o aplicativo nativo SwiftUI,
independente do REA, sob MIT, com limpeza, arquivos grandes, desinstalação e
distribuição Homebrew. O nome definido pelo usuário é Zé Coleta; o identificador
de distribuição é `ze-coleta`.

## Produto

Quatro destinos: visão geral, limpeza, arquivos grandes e aplicativos.
Interface em português, fundo claro e verde como cor de ação. A análise é
somente leitura. Os resultados mostram os caminhos, tamanhos, motivos de
seleção e limitações. Nenhum item é selecionado automaticamente. A ação de
remoção exige revisão explícita e usa a Lixeira do macOS.

Limpeza examina os filhos de `~/Library/Caches`, `~/Library/Logs` e
`~/Library/Developer/Xcode/DerivedData`. Arquivos grandes examina pastas
escolhidas pelo usuário, inicialmente Downloads, com limite de tamanho
configurável. Aplicativos inventaria `/Applications` e `~/Applications`,
excluindo remoção de apps de sistema e do próprio Zé Coleta. Arquivos
relacionados por bundle ID são candidatos inferidos, exigem seleção separada
e ficam limitados a caches, logs e ao arquivo de preferências com ID exato.
Contêineres, grupos compartilhados e Application Support são preservados.

## Núcleo

`ColetaCore` possui os modelos, scanner e política de remoção. `ZeColeta`
possui a interface, o estado de tarefas, seletores e integração com Finder.
A varredura roda fora da thread da interface, admite cancelamento e produz
resultados parciais quando encontra permissões ausentes ou limites.

URLs de origem, raiz autorizada, categoria e identidade do arquivo permanecem
associadas a cada candidato. O serviço de Lixeira revalida identidade, raiz e
ancestrais antes da ação. Links simbólicos não são seguidos. Locais de nuvem,
pacotes de fotos e diretórios de sistema não são alvos de limpeza nesta
versão. Apps abertos são bloqueados antes da desinstalação. Sucessos e falhas
são reportados por item; falhas não são convertidas em sucesso.

## Distribuição

Swift Package sem dependências externas, macOS 14+, app universal arm64 e
x86_64. Script gera `Zé Coleta.app` e ZIP versionado, com checksum. O código
e automações ficam em `xenofonteicaro/ze-coleta`; o tap fica em
`xenofonteicaro/homebrew-tap`.

Uma fórmula compila o código localmente e instala o app. Um Cask usa o ZIP
de release e SHA-256. Publicação de binário notarizado depende de certificado
Developer ID e credenciais Apple, indisponíveis nesta sessão; não remover
quarantine nem desativar Gatekeeper em scripts. A instalação por fonte deve
ser verificável sem essas credenciais.

## Verificação

Testes em diretórios temporários verificam seleção por categoria, ordenação,
permissões/erros, limites, cancelamento, exclusão de links, mudança de
identidade, ancestrais substituídos e bloqueio de caminhos fora da raiz.
Remoção real é testada apenas com arquivos descartáveis criados pelo teste.
Build e smoke da interface devem usar o app real. Pacotes são verificados
com comandos Homebrew apropriados. Nenhuma limpeza dos arquivos pessoais do
usuário integra a validação.
