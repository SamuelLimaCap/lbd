# lbd

Neovim (LazyVim) usado como cliente de banco de dados, com o [nvim-dbee](https://github.com/kndndrj/nvim-dbee).
Funciona com Oracle (testado no 11.2) e Postgres (testado no 15). Abre com `lbd` (`NVIM_APPNAME=lbd nvim`).

O dbee usa drivers próprios, escritos em Go: **não precisa** de `psql`, `sqlplus` nem Oracle Instant Client.

- [Instalação](#instalação)
- [Arquivos fora do repositório](#arquivos-fora-do-repositório)
- [Atalhos principais](#atalhos-principais)
- [Usar com Docker](docs/docker.md)

## Instalação

```bash
git clone git@github.com:SamuelLimaCap/lbd.git ~/nvim-configs/lbd
ln -s ~/nvim-configs/lbd ~/.config/lbd
echo "alias lbd='NVIM_APPNAME=lbd nvim'" >> ~/.bashrc && source ~/.bashrc

# conexões (ver o modelo abaixo)
mkdir -p ~/.local/share/lbd
$EDITOR ~/.local/share/lbd/conexoes.json
chmod 600 ~/.local/share/lbd/conexoes.json

lbd   # na 1ª abertura baixa os plugins e o binário do dbee
```

Precisa de: Neovim 0.10 ou mais novo, git, curl e python3 (formatar JSON/XML no painel de valor da grade).
Se o binário do dbee não vier, rode `:lua require('dbee').install()` dentro do lbd.

Clone em `~/nvim-configs/lbd`: o [lvim-dbupdater](https://github.com/SamuelLimaCap/lvim-dbupdater)
usa o `lua/lbd/sql.lua` daqui por esse caminho.

## Arquivos fora do repositório

Dentro do lbd, `<leader>fx` (ou `:Externos`) lista estes caminhos e mostra quais existem na máquina.

| Caminho | Para quê | Obrigatório |
|---|---|---|
| `~/.local/share/lbd/conexoes.json` | conexões, **com usuário e senha** | sim |
| `~/.local/share/lbd/dbee/` | binário do dbee, notas e histórico de queries | criado sozinho |
| `~/.local/share/lbd/lazy/`, `mason/` | plugins e o `sql-formatter` (`<leader>cf`) | criados sozinhos |
| `~/projetos/cobol/desk/FONTESBD` | busca nos fontes COBOL | não |
| `~/Documents/obsidian/Geral` | cofre do Obsidian (obsidian.nvim) | não |

### `conexoes.json`

É uma lista JSON no formato do `FileSource` do dbee. Também dá para criar as conexões pela tela do dbee
(`<leader>D`): ele grava no mesmo arquivo.

```json
[
  {
    "id": "pg-local",
    "name": "Postgres local",
    "type": "postgres",
    "url": "postgres://USUARIO:SENHA@localhost:5432/NOME_DO_BANCO?sslmode=disable"
  },
  {
    "id": "oracle-sinc1",
    "name": "sinc1 (192.168.0.10)",
    "type": "oracle",
    "url": "oracle://USUARIO:SENHA@192.168.0.10:1521/SERVICO?TIMEOUT=300"
  }
]
```

| Campo | O quê |
|---|---|
| `id` | identificador único; não mude depois de criar (o histórico e as notas usam o id) |
| `name` | nome que aparece na árvore do dbee; o lvim-dbupdater usa a 1ª palavra como nome da base |
| `type` | `postgres` ou `oracle` (outros tipos do dbee também funcionam, mas os módulos `lbd.*` só tratam esses dois) |
| `url` | Postgres: `postgres://usuario:senha@host:porta/banco?sslmode=disable`<br>Oracle: `oracle://usuario:senha@host:porta/SERVICO?TIMEOUT=300` (o 3º trecho é o *service name*, não o SID) |

Senha com caractere especial (`@`, `:`, `/`, `#`, `%`) precisa ir codificada na URL: `@` → `%40`,
`#` → `%23`, `%` → `%25`, `/` → `%2F`, `:` → `%3A`.

No Postgres, `<leader>ds` lista os outros databases do mesmo servidor, então uma conexão por servidor basta.
No Oracle, o mesmo atalho lista os schemas.

## Atalhos principais

| Atalho | O quê |
|---|---|
| `<leader>D` | abre/fecha o dbee |
| `BB` | roda o arquivo (normal) ou a seleção (visual) |
| `BQ` | roda a query sob o cursor (até o `;`, ou o `/` no PL/SQL) |
| `<leader>ds` | troca o database (Postgres) ou o schema (Oracle) |
| `<leader>dc` / `<leader>dC` | colunas da tabela (+ Java/Hibernate) |
| `<leader>da` / `<leader>dl` | roda a query em várias bases (lote) / reabre a lista |
| `<leader>do` `<leader>dt` `<leader>dd` `<leader>dO` | código de procedure/view, triggers, CREATE de tabela, objeto sob o cursor |
| `<leader>cf` | formata o SQL no dialeto da conexão ativa |
| `<leader>fx` | arquivos fora do `~/.config` |

`:BancoAjuda` (ou `?` na árvore do dbee) mostra todos.
