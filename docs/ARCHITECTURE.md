# Arquitetura

## Objetivo

O projeto controla um firewall Linux que atua como roteador entre redes internas e externas. A primeira geração é orientada principalmente a tráfego **de dentro para fora**.

## Pipeline atual

1. `regras_firewall.conf` é lido e validado;
2. regras `d:` e `s:` são deduplicadas;
3. FQDNs são resolvidos para IPv4, com cache de contingência;
4. redes são consolidadas com `ipaddress.collapse_addresses()` quando Python 3 está disponível;
5. destinos e origens são carregados em `ipset`;
6. `iptables-restore` aplica as tabelas `filter` e `nat` em lote;
7. toda alteração destrutiva é precedida por backup e protegida por rollback.

## Sets

- `FWU_DST_V4`: destinos permitidos;
- `FWU_SRC_V4`: origens permitidas.

O objetivo é manter o número de regras pequeno, mesmo quando a política contém dezenas de milhares de endereços.

## Modelo stateful

A partir da v2.1, `FORWARD` aceita `ESTABLISHED,RELATED` antes de avaliar novas conexões e descarta `INVALID`. Isso permite construir regras de entrada e saída com uma política final explícita de DROP.

## Separação proposta

A evolução do projeto deve separar três classes de política:

1. **outbound** — clientes internos iniciando conexões para fora;
2. **inbound-forward** — publicação/DNAT de serviços internos para a Internet;
3. **inbound-local** — serviços que terminam no próprio firewall.

Essa separação evita confundir `INPUT` com `FORWARD`, que possuem riscos e semânticas diferentes.

## Backend

A v2.x permanece em `iptables` + `ipset` por compatibilidade com EL7/EL8/EL9 e com o ambiente existente. A arquitetura deve evitar dependências que impeçam um backend futuro em `nftables`.
