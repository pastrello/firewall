# Dynamic DNS outbound — v2.3

## Objetivo

O tipo `u:` representa um destino permitido cujo IPv4 pode mudar durante o dia:

```text
u: pastrello.ddns.net
```

Diferentemente de um FQDN em `d:`, resolvido no `apply`/`refresh-sets`, um `u:` é acompanhado continuamente pelo `firewall-dnswatch.service`.

## Set dedicado

Os IPv4 atuais ficam em `FWU_DYN_DST_V4`. O ruleset contém somente:

```text
-A FORWARD -m set --match-set FWU_DYN_DST_V4 dst -j ACCEPT
```

A atualização usa `ipset swap`, sem reconstruir chains iptables.

## Instalação

O watcher requer `dig` (`bind-utils`):

```bash
dnf install bind-utils
# EL7: yum install bind-utils
```

Depois:

```bash
./firewall_unidades.sh installservice
```

O instalador valida dependências/configuração, grava `/etc/systemd/system/firewall-dnswatch.service`, executa `daemon-reload` e `enable --now`.

O unit aponta para o caminho absoluto do script usado na instalação. Se o projeto for movido, execute `installservice` novamente.

## TTL e intervalo

```text
intervalo = TTL / DYNAMIC_DNS_TTL_DIVISOR
```

limitado por:

```bash
DYNAMIC_DNS_MIN_INTERVAL=30
DYNAMIC_DNS_MAX_INTERVAL=300
DYNAMIC_DNS_TTL_DIVISOR=2
```

Com os defaults: TTL 30 -> 30s; TTL 60 -> 30s; TTL 300 -> 150s; TTL 3600 -> 300s. Havendo vários `u:`, o ciclo usa o menor intervalo necessário.

Todos os registros A retornados para o hostname entram no set.

## Troca de IP e grace

```bash
DYNAMIC_DNS_GRACE=300
```

O novo IP entra imediatamente. O anterior permanece durante o grace para clientes que ainda o tenham em cache. Conexões existentes continuam cobertas por `ESTABLISHED,RELATED`.

## Falhas DNS

Uma falha de consulta nunca esvazia o hostname imediatamente:

```bash
DYNAMIC_DNS_STALE_MAX=3600
DYNAMIC_DNS_FAIL_POLICY="keep"
```

Dentro de `STALE_MAX`, o status é `CACHE`. Depois disso, `keep` mantém o IP como `STALE_KEEP`; `drop` remove o endereço expirado. O padrão é `keep`.

## Estado persistente

```text
.firewall-v2/dynamic/state.tsv
.firewall-v2/dynamic/status.tsv
.firewall-v2/dynamic/meta.env
```

O backup inclui esse estado e `FWU_DYN_DST_V4`.

## Concorrência

O watcher usa o mesmo lock de `apply`, `rollback` e `refresh-sets`. Se estiver ocupado, aguarda `DYNAMIC_DNS_LOCK_TIMEOUT` e tenta novamente no ciclo seguinte.

## Operação

```bash
./firewall_unidades.sh dynamic-status
./firewall_unidades.sh dynamic-refresh
./firewall_unidades.sh installservice
./firewall_unidades.sh uninstallservice
journalctl -u firewall-dnswatch.service
```

`uninstallservice` preserva o ipset e estado atuais.

## Segurança e limitações

`u:` é autorização baseada em DNS. Comprometimento da zona/conta DDNS pode fazer o firewall acompanhar um endereço controlado por terceiro. Use nomes sob controle confiável.

Em CDNs/Cloudflare e hospedagem compartilhada, liberar o IP retornado pode liberar outros serviços naquele mesmo IP; isso não equivale a filtro HTTP Host ou TLS SNI.

A v2.3 acompanha somente registros IPv4 A.
