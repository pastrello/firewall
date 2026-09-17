# Arquitetura

## Objetivo

O projeto controla um firewall Linux que atua como roteador entre redes internas e externas. A geração atual é orientada principalmente a tráfego **de dentro para fora**.

## Pipeline atual

1. `regras_firewall.conf` é lido e validado;
2. regras `d:`, `u:` e `s:` são deduplicadas;
3. FQDNs `d:`/`s:` são resolvidos para IPv4 com cache de contingência;
4. redes estáticas são consolidadas quando Python 3 está disponível;
5. destinos/origens são carregados em `ipset`;
6. `iptables-restore` aplica `filter` e `nat` em lote;
7. alterações destrutivas são precedidas por backup/rollback;
8. opcionalmente, o watcher v2.3 mantém `u:` sincronizado sem reconstruir o ruleset.

## Sets

- `FWU_DST_V4`: destinos `d:`;
- `FWU_DYN_DST_V4`: destinos `u:` dinâmicos;
- `FWU_SRC_V4`: origens permitidas.

## DNS estático versus dinâmico

`d: hostname` é um snapshot atualizado por `apply`/`refresh-sets`.

`u: hostname` é dependência DNS contínua. O daemon consulta TTL, mantém grace/stale state e troca somente `FWU_DYN_DST_V4` via `ipset swap`.

O watcher compartilha o lock das operações principais e persiste estado em `.firewall-v2/dynamic/`.

## Modelo stateful

`FORWARD` aceita `ESTABLISHED,RELATED` antes de novas conexões e descarta `INVALID`, permitindo política final explícita de DROP.

## Papéis de interface

A v2.2 separa WAN/LAN/VPN e impede confiança genérica de WAN no modo `roles`, pré-requisito para inbound.

## Separação de política

1. **outbound-static** — `d:` e regras tradicionais;
2. **outbound-dynamic** — `u:` mantido pelo watcher;
3. **inbound-forward** — publicação/DNAT de serviços internos;
4. **inbound-local** — serviços no próprio firewall.

## Backend

A v2.x permanece em `iptables` + `ipset` por compatibilidade com EL7/EL8/EL9. A arquitetura evita acoplamento desnecessário para permitir backend futuro em `nftables`.
