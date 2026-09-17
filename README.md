# Firewall Unidades

Firewall Linux otimizado para listas extensas de autorização, inicialmente **dentro → fora**, preparado para evoluir para **fora → dentro**. Compatibilidade alvo: CentOS/RHEL/Rocky Linux 7, 8 e 9 com `iptables` + `ipset`.

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

- `d:` destino estático/snapshot DNS atualizado em `apply` ou `refresh-sets`;
- `u:` FQDN de destino dinâmico acompanhado continuamente pela v2.3;
- `s:` origem liberada;
- `p:` porta TCP global;
- `m:` MAC para TCP/443;
- `c:` MAC com FORWARD total.

`u:` aceita somente FQDN. IP/CIDR estático continua em `d:`.

## v2.3 — Dynamic DNS outbound

A v2.3 adiciona `FWU_DYN_DST_V4` e uma única regra:

```text
-A FORWARD -m set --match-set FWU_DYN_DST_V4 dst -j ACCEPT
```

O daemon consulta os nomes `u:`, usa o TTL DNS e troca o set atomicamente sem recriar o firewall.

```text
u: pastrello.ddns.net
u: filial01.example.net
```

O watcher requer `dig` (`bind-utils`):

```bash
dnf install bind-utils
# EL7: yum install bind-utils
```

Instale o serviço diretamente pelo gerenciador:

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

Remoção:

```bash
./firewall_unidades.sh uninstallservice
```

A remoção preserva o ipset e o estado atual.

### TTL, grace e falhas

O intervalo é `TTL / DYNAMIC_DNS_TTL_DIVISOR`, limitado por `DYNAMIC_DNS_MIN_INTERVAL` e `DYNAMIC_DNS_MAX_INTERVAL`.

Quando o DNS troca de IP, o novo endereço entra imediatamente e o antigo permanece por `DYNAMIC_DNS_GRACE` para clientes com cache anterior.

Em falha DNS, o último estado válido é preservado. Depois de `DYNAMIC_DNS_STALE_MAX`:

- `DYNAMIC_DNS_FAIL_POLICY=keep` mantém o IP e marca `STALE_KEEP`;
- `drop` remove o IP expirado.

O padrão é `keep`.

Veja `docs/DYNAMIC-DNS.md`.

## v2.2 — hardening de interfaces

```bash
INTERFACE_POLICY_MODE="compat"   # compat | roles
WAN_INTERFACES="eth1"
LAN_INTERFACES="eth0"
VPN_INTERFACES="wg0"
```

Em `roles`, somente LAN/VPN recebem confiança genérica em INPUT; WAN nunca recebe. Veja `docs/V2.2-MIGRATION.md`.

## Instalação

```bash
mkdir -p /operacao/firewall.unidades
cp firewall_unidades.sh /operacao/firewall.unidades/
cp -r lib /operacao/firewall.unidades/
cp firewall_unidades.conf.example /operacao/firewall.unidades/firewall_unidades_v2.conf
chmod 700 /operacao/firewall.unidades/firewall_unidades.sh
chmod 600 /operacao/firewall.unidades/firewall_unidades_v2.conf
```

Dependências: `iptables`, `iptables-save`, `iptables-restore`, `ipset`, `getent`, `timeout`, `flock`, `awk`, `sort`, `cmp`. Para o watcher `u:` também é necessário `dig`. Python 3 é opcional para consolidação CIDR.

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

Atualização manual dos conjuntos:

```bash
./firewall_unidades.sh refresh-sets
```

Rollback:

```bash
./firewall_unidades.sh backups
./firewall_unidades.sh rollback
```

## Segurança

O arquivo real `regras_firewall.conf`, configurações locais, estado, backups e logs não devem ser versionados.

`u:` é autorização baseada em DNS: comprometimento da zona/conta DDNS pode fazer o firewall acompanhar um IP malicioso. Em CDNs/Cloudflare, liberar o IP retornado não equivale a filtro por hostname HTTP/SNI e pode alcançar outros serviços no mesmo IP compartilhado.

## Inbound

O futuro modelo **fora → dentro** permanece descrito em `docs/INBOUND.md`. A infraestrutura DNS dinâmica da v2.3 poderá ser reutilizada para grupos de origem dinâmicos.

## Documentação

- `docs/ARCHITECTURE.md`
- `docs/V2.2-MIGRATION.md`
- `docs/DYNAMIC-DNS.md`
- `docs/INBOUND.md`
- `CHANGELOG.md`
