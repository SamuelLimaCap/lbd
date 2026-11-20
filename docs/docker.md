# lbd com Docker

Há dois jeitos de juntar o lbd com o Docker:

1. **[Bancos no Docker, lbd na máquina](#1-bancos-no-docker-lbd-na-máquina)**: o caso mais comum, para ter
   um Postgres/Oracle local de teste.
2. **[O próprio lbd dentro de um container](#2-o-lbd-dentro-de-um-container)**: para usar numa máquina
   sem instalar Neovim, plugins etc.

> Os exemplos não foram testados na máquina onde este guia foi escrito, que não tem Docker.
> Os comandos seguem a documentação das imagens; se algo falhar, abra uma issue ou ajuste.

---

## 1. Bancos no Docker, lbd na máquina

### Subir os bancos

Crie uma pasta, por exemplo `~/docker/bancos/`, com este `compose.yaml`:

```yaml
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: lbd
      POSTGRES_PASSWORD: lbd123
      POSTGRES_DB: teste
    ports:
      - "5432:5432"          # porta da máquina:porta do container
    volumes:
      - pg-dados:/var/lib/postgresql/data

  oracle:
    # Oracle XE 11g (o mesmo 11.2 do sinc). Para um Oracle novo: gvenzl/oracle-xe:21-slim
    image: gvenzl/oracle-xe:11-slim
    environment:
      ORACLE_PASSWORD: oracle123       # senha do SYSTEM
      APP_USER: lbd                    # cria um usuário/schema comum
      APP_USER_PASSWORD: lbd123
    ports:
      - "1521:1521"
    volumes:
      - ora-dados:/u01/app/oracle/oradata
    shm_size: 1g

volumes:
  pg-dados:
  ora-dados:
```

```bash
cd ~/docker/bancos
docker compose up -d
docker compose logs -f oracle     # espere "DATABASE IS READY TO USE!" (1ª vez: 1 a 3 minutos)
```

Se a porta 5432 ou 1521 já estiver em uso na máquina, troque só o lado esquerdo, por exemplo `"15432:5432"`,
e use `15432` na URL.

### Conexões no `~/.local/share/lbd/conexoes.json`

```json
[
  {
    "id": "docker-pg",
    "name": "docker-pg (localhost)",
    "type": "postgres",
    "url": "postgres://lbd:lbd123@localhost:5432/teste?sslmode=disable"
  },
  {
    "id": "docker-ora",
    "name": "docker-ora (localhost)",
    "type": "oracle",
    "url": "oracle://lbd:lbd123@localhost:1521/XE?TIMEOUT=300"
  }
]
```

O serviço do Oracle XE 11 é `XE`; no 21 é `XEPDB1`. Abra o lbd, `<leader>D` e escolha a conexão.

### Carregar dados de teste

```bash
# Postgres: roda um .sql no container
docker compose exec -T postgres psql -U lbd -d teste < dump.sql

# Oracle: sqlplus de dentro do container
docker compose exec -T oracle sqlplus -s lbd/lbd123@XE < script.sql
```

Também dá para colar o script no lbd e rodar com `BB`.

### Parar e apagar

```bash
docker compose stop        # para, mantém os dados
docker compose down        # remove os containers, mantém os volumes (dados)
docker compose down -v     # remove TUDO, inclusive os dados
```

---

## 2. O lbd dentro de um container

A imagem leva o Neovim, a config do lbd e os plugins já baixados. As conexões **não** entram na imagem:
são montadas na hora de rodar, para nunca irem parar num registry.

### Dockerfile

Salve como `Dockerfile` na raiz deste repositório (ao lado do `init.lua`):

```dockerfile
FROM debian:bookworm-slim

ARG NVIM_VERSION=v0.11.4
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 ripgrep fd-find unzip nodejs npm make gcc locales \
 && sed -i 's/# pt_BR.UTF-8/pt_BR.UTF-8/' /etc/locale.gen && locale-gen \
 && curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
      | tar -xz -C /opt \
 && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=pt_BR.UTF-8 NVIM_APPNAME=lbd TERM=xterm-256color
RUN useradd -m lbd
USER lbd
WORKDIR /home/lbd

COPY --chown=lbd:lbd . /home/lbd/.config/lbd

# baixa plugins (versões do lazy-lock.json), o binário do dbee e o sql-formatter
RUN nvim --headless "+Lazy! restore" +qa \
 && nvim --headless "+Lazy! build nvim-dbee" +qa \
 && nvim --headless "+MasonInstall sql-formatter" +qa || true

ENTRYPOINT ["nvim"]
```

Crie também um `.dockerignore` para não copiar lixo:

```
.git
dadbod_ui
```

### Construir e rodar

```bash
cd ~/nvim-configs/lbd
docker build -t lbd .

docker run -it --rm \
  -v ~/.local/share/lbd/conexoes.json:/home/lbd/.local/share/lbd/conexoes.json \
  -v "$PWD/consultas":/home/lbd/consultas \
  --add-host=host.docker.internal:host-gateway \
  lbd
```

- `-it` é obrigatório: o Neovim precisa de terminal.
- O 1º `-v` monta as conexões da máquina. Para só leitura, acrescente `:ro` no fim; aí não dá para criar
  conexões pela tela do dbee.
- O 2º `-v` é opcional: uma pasta da máquina para salvar os `.sql`.
- Para que as notas e o histórico do dbee sobrevivam ao `--rm`, monte um volume em
  `/home/lbd/.local/share/lbd/dbee`.

Um alias para não digitar tudo:

```bash
alias lbd-docker='docker run -it --rm -v ~/.local/share/lbd/conexoes.json:/home/lbd/.local/share/lbd/conexoes.json --add-host=host.docker.internal:host-gateway lbd'
```

### Endereço do banco visto de dentro do container

Dentro do container, `localhost` é o próprio container, não a sua máquina.

| Onde está o banco | Host na URL |
|---|---|
| outra máquina da rede (ex.: `192.168.0.10`) | o IP normal, nada muda |
| na sua máquina (fora do Docker) | `host.docker.internal` (precisa do `--add-host` acima) |
| outro container do compose da [seção 1](#1-bancos-no-docker-lbd-na-máquina) | o nome do serviço (`postgres`, `oracle`), rodando o lbd na mesma rede: `--network bancos_default` |

Exemplo com o lbd na rede do compose:

```bash
docker run -it --rm --network bancos_default \
  -v ~/docker/bancos/conexoes-docker.json:/home/lbd/.local/share/lbd/conexoes.json lbd
```

com `conexoes-docker.json` usando `postgres://lbd:lbd123@postgres:5432/teste?sslmode=disable` e
`oracle://lbd:lbd123@oracle:1521/XE?TIMEOUT=300`.

### Atualizar a imagem

Depois de um `git pull` neste repositório, rode `docker build -t lbd .` de novo.
