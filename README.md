# Zé Coleta

Um utilitário macOS open source para revisar arquivos temporários, encontrar
arquivos grandes e desinstalar aplicativos. Implementação independente em
SwiftUI, com processamento local e licença MIT.

Primeira versão experimental: macOS 14 ou posterior, Intel e Apple Silicon.
O primeiro release e o tap são preparados no pull request de implementação
inicial; a instalação pública depende da publicação desses artefatos.

## Instalação pelo Homebrew

Após a publicação do tap:

```sh
brew install --formula xenofonteicaro/tap/ze-coleta
ze-coleta
```

A fórmula compila o aplicativo localmente e exige Xcode 16 ou posterior já
instalado. Ela não instala Xcode, não remove quarantine e não altera
Gatekeeper. Não é necessário certificado Developer ID para esse build local.
O app fica no prefixo gerenciado pelo brew e o comando `ze-coleta` o abre.

```sh
ze-coleta --version
brew upgrade ze-coleta
brew uninstall ze-coleta
```

O Cask para um binário pré-compilado também tem gerador em
`scripts/generate-cask.sh`. Sua distribuição notarizada depende de Developer
ID e notarização Apple. O primeiro caminho suportado é a fórmula por fonte;
o Cask não está ativo no tap inicial.

## O que faz

- **Limpeza:** lista arquivos e pastas em caches, registros do usuário e
  DerivedData do Xcode. Você escolhe cada item.
- **Arquivos grandes:** encontra arquivos locais acima de 100 MB, 500 MB ou
  1 GB nas pastas escolhidas. Toda a `~/Library`, links, pacotes e bibliotecas de dados são
  excluídos; a cobertura parcial é identificada.
- **Aplicativos:** examina os apps do primeiro nível de `/Applications` e
  `~/Applications`. Caches, logs e preferências com bundle ID exato são
  candidatos inferidos, com seleção separada. Contêineres, dados de
  Application Support e grupos compartilhados ficam preservados.
- **Revisão:** mostra os caminhos selecionados antes de enviar à Lixeira.
  Apps em uso e itens cuja identidade mudou são bloqueados.

Analisar só lê arquivos. Mover para a Lixeira não libera espaço imediatamente;
os itens continuam recuperáveis pelo Finder. O app não esvazia a Lixeira.
Os tamanhos são somas lógicas, não uma previsão de espaço físico recuperável
em APFS, arquivos esparsos ou hard links.

Os limites padrão são 250.000 entradas examinadas e 1.000 candidatos
retidos por análise. Erros de acesso, exclusões e limites aparecem no
resultado. Um resultado parcial não estabelece que os demais locais estejam
vazios. Uma análise específica de cada seção evita que o limite geral da
visão geral reduza os resultados desejados.

## Desenvolvimento

Sem dependências externas de Swift Package Manager:

```sh
swift test
bash scripts/build-app.sh
open 'build/Zé Coleta.app'
```

O script gera um aplicativo universal e um ZIP com SHA-256. Para um build
somente da arquitetura do seu Mac:

```sh
COLETA_ARCHS=native bash scripts/build-app.sh
```

Sem `DEVELOPER_ID_APPLICATION`, o bundle recebe assinatura ad hoc para uso
local. Essa assinatura não é notarização nem prova de aprovação pelo
Gatekeeper de um download. O workflow de release prepara artefatos em draft,
sem publicar binários automaticamente. Nenhuma chave ou identidade Apple é
armazenada no repositório.

## Escopo e evidência

O [relatório da investigação](docs/reconstruction.md) distingue os fatos
observados no aplicativo instalado, inferências e verificações ausentes.
O [desenho](docs/design.md) registra o escopo aprovado. A alternativa não
incorpora código, arte ou base de regras do CleanMyMac e não promete
equivalência completa, antivírus ou limpeza de nuvem.

A política revalida dispositivo, inode, alterações do item e os ancestrais
antes de mover. A API Foundation de Lixeira recebe caminhos: permanece uma
janela de corrida com alterações concorrentes do sistema de arquivos. Essa
validação não oferece uma transação atômica contra outro processo malicioso.
Selecionar uma pasta autoriza seu conteúdo inteiro. O scan não é uma cópia
congelada de cada arquivo interno; alterações profundas de mesmo tamanho
podem não ser detectadas pelas identidades e medidas agregadas.

Licença [MIT](LICENSE).
