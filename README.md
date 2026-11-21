# Firewall Unidades

Firewall Linux otimizado para listas extensas de autorização, inicialmente **dentro → fora**, preparado para evoluir para **fora → dentro** e múltiplos backends. Na v2.4 o backend operacional permanece `iptables` + `ipset`; a arquitetura já está desacoplada para receber `nftables`.

## Formato outbound

```text
d: 203.0.113.10
d: api.example.com
u: filial.ddns.example.net
s: 10.40.0.0/16
p: 443
m: 02:00:00:00:00:10
c: 02:00:00:00:00:20
```

`d:` é destino estático/snapshot DNS; `u:` é FQDN de destino dinâmico; `s:` libera origem; `p:` porta TCP global; `m:` MAC para HTTPS; `c:` MAC com FORWARD total. `u:` aceita somente FQDN.

## v2.4 — abstração de backend

A v2.4 separa a política e a operação do mecanismo de firewall. A configuração passa a declarar explicitamente:

~~~bash
BACKEND="iptables"
~~~

Não há seleção automática. `nftables` está reservado para a v2.5 e não pode ser selecionado na v2.4.

A API interna cobre geração, validação, aplicação, backup/restore e operações de conjuntos. Parser, DNS, watcher `u:`, interfaces e comandos deixam de depender diretamente de `iptables`/`ipset`.

Diagnóstico:

~~~bash
./firewall_unidades.sh backend-info
~~~

## v2.3 — Dynamic DNS outbound

A v2.3 adiciona `FWU_DYN_DST_V4` e uma única regra:

```text
-A FORWARD -m set --match-set FWU_DYN_DST_V4 dst -j ACCEPT
```

O daemon consulta os nomes `u:`, usa o TTL DNS e troca o set atomicamente sem recriar o firewall.

O watcher requer `dig` (`bind-utils`):

```bash
dnf install bind-utils
# EL7: yum install bind-utils
```

Depois de aplicar o ruleset, instale o serviço diretamente pelo gerenciador:

```bash
./firewall_unidades.sh installservice
```

O comando valida dependências/configuração, cria `/etc/systemd/system/firewall-dnswatch.service`, executa `daemon-reload` e `enable --now`.

Operação:

```bash
./firewall_unidades.sh dynamic-status
./firewall_unidades.sh dynamic-refresh
systemctl status firewall-dnswatch.service
journalctl -u firewall-dnswatch.service
```

Remoção (preserva ipset/estado):

```bash
./firewall_unidades.sh uninstallservice
```

### TTL, grace e falhas

Intervalo = `TTL / DYNAMIC_DNS_TTL_DIVISOR`, limitado por MIN/MAX. Na troca de IP, o novo entra imediatamente e o antigo permanece por `DYNAMIC_DNS_GRACE`. Em falha DNS, o último estado válido é preservado; após `DYNAMIC_DNS_STALE_MAX`, `keep` mantém como `STALE_KEEP` e `drop` remove.

Detalhes: `docs/DYNAMIC-DNS.md`.

## v2.2 — hardening de interfaces

```bash
INTERFACE_POLICY_MODE="compat"   # compat | roles
WAN_INTERFACES="eth1"
LAN_INTERFACES="eth0"
VPN_INTERFACES="wg0"
```

Em `roles`, somente LAN/VPN recebem confiança genérica em INPUT; WAN nunca recebe. Veja `docs/V2.2-MIGRATION.md`.

## Instalação e upgrade

Para uma instalação nova a partir de um clone/cópia atual do repositório:

~~~bash
bash install.sh install /operacao/firewall.unidades
~~~

O instalador cria uma configuração mínima segura apenas se ela não existir, com `LOG_TRAFFIC=0`, e cria `regras_firewall.conf` vazio. Ele **não aplica o firewall automaticamente**.

Para atualizar uma instalação antiga usando uma cópia nova do repositório:

~~~bash
bash install.sh upgrade /operacao/firewall.unidades
~~~

Ou, depois que a versão 2.4.3+ já estiver instalada:

~~~bash
./firewall_unidades.sh upgrade
~~~

Quando o diretório instalado é também um checkout Git, `upgrade` executa `git pull --ff-only`. Se houver alterações locais em arquivos versionados, o upgrade é recusado. Configuração, regras e `.firewall-v2` são preservados.

Antes de substituir a aplicação, é criado backup em:

~~~text
/operacao/firewall.unidades/.app-backups/YYYYMMDD_HHMMSS/
~~~

A retenção padrão é `APP_BACKUP_KEEP=5`. Após a troca, o instalador executa validação de sintaxe e `check`; se a validação falhar, restaura a versão anterior da aplicação. Se o `firewall-dnswatch.service` estiver ativo, ele é reiniciado após upgrade bem-sucedido.

## Instalação manual

```bash
mkdir -p /operacao/firewall.unidades
cp firewall_unidades.sh /operacao/firewall.unidades/
cp -r lib /operacao/firewall.unidades/
cp firewall_unidades.conf.example /operacao/firewall.unidades/firewall_unidades_v2.conf
chmod 700 /operacao/firewall.unidades/firewall_unidades.sh
chmod 600 /operacao/firewall.unidades/firewall_unidades_v2.conf
```

Dependências do backend `iptables`: `iptables`, `iptables-save`, `iptables-restore`, `ipset`, `getent`, `timeout`, `flock`, `awk`, `sort`, `cmp`. Para `u:` também é necessário `dig`. Python 3 é opcional para consolidação CIDR.

## Fluxo seguro

```bash
./firewall_unidades.sh diagnose
./firewall_unidades.sh check --resolve
./firewall_unidades.sh generate 192.168.11.1
# revise .firewall-v2/runtime/current/iptables.rules
./firewall_unidades.sh apply 192.168.11.1
./firewall_unidades.sh installservice   # se houver u:
./firewall_unidades.sh dynamic-status
```

Testes locais:

~~~bash
bash tests/test_v22_policy.sh
bash tests/test_v23_dynamic.sh
bash tests/test_v24_backend.sh
~~~

O repositório também executa esses testes e `bash -n` via GitHub Actions.

Atualização manual/rollback:

```bash
./firewall_unidades.sh refresh-sets
./firewall_unidades.sh backups
./firewall_unidades.sh rollback
```

## Segurança

Não versione o arquivo real `regras_firewall.conf`, configurações locais, estado, backups ou logs.

`u:` é autorização baseada em DNS: comprometimento da zona/conta DDNS pode fazer o firewall acompanhar um IP malicioso. Em CDNs/Cloudflare, liberar o IP retornado não equivale a filtro por hostname HTTP/SNI e pode alcançar outros serviços no mesmo IP compartilhado.

## Inbound

O futuro modelo **fora → dentro** permanece em `docs/INBOUND.md`. A infraestrutura DNS dinâmica da v2.3 poderá ser reutilizada para grupos de origem dinâmicos.

## Documentação

- `docs/ARCHITECTURE.md`
- `docs/V2.2-MIGRATION.md`
- `docs/DYNAMIC-DNS.md`
- `docs/INBOUND.md`
- `docs/ROADMAP.md`
- `CHANGELOG.md`
